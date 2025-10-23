# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "yaml"
require "base64"
require "uri"

require_relative "non_reentrant_connection_pool"

# A Kubernetes client built with minimal dependencies while keeping the API elegant.
#
# - Convention over configuration used where possible, e.g. automatically detects
#   in-cluster (ServiceAccount) or out-of-cluster (KUBECONFIG) configuration.
# - Thread safe connection pooling is used to efficiently manage persistent HTTP connections.
# - Provides basic CRUD operations and watch support for Kubernetes resources.
#
# Example usage:
#   Kubernetes.statefulsets.list(namespace: "default")
#   Kubernetes.secrets.get("my-secret", namespace: "default")
#   Kubernetes.services.create({ ... })
#   Kubernetes.deploymnents.watch(namespace: "default", resource_version: "12345") do |event|
#     puts event
#   end
#
# Resources are generic and can be used for any Kubernetes resource by specifying the plural name,
# API version and group if needed.
#
#   my_custom_resource = Kubernetes::Resource.new("mycustomresources", group: "mygroup.example.com", version: "v1alpha1")

module Kubernetes
  class Error < StandardError; end

  # Configurable field manager name for server-side apply operations
  mattr_accessor :field_manager
  self.field_manager = "kubernetes-rb"

  TRANSIENT_NET_ERRORS = [
    EOFError,
    IOError,
    Errno::ECONNRESET,
    Errno::EPIPE,
    Errno::ETIMEDOUT,
    Errno::EBADF,
    Net::OpenTimeout,
    Net::ReadTimeout,
    Net::WriteTimeout,
    Net::HTTPBadResponse,
  ].freeze

  # Returns the memory size in bytes
  # https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/#meaning-of-memory
  def self.parse_memory(memory_string)
    case memory_string
    when /\A(\d+)(Ei|Pi|Ti|Gi|Mi|Ki|E|P|T|G|M|K)?\z/
      size = Integer(Regexp.last_match(1))
      unit = Regexp.last_match(2)

      multiplier =
        case unit
        when "Ei" then 1024**6
        when "Pi" then 1024**5
        when "Ti" then 1024**4
        when "Gi" then 1024**3
        when "Mi" then 1024**2
        when "Ki" then 1024**1
        when "E" then 1000**6
        when "P" then 1000**5
        when "T" then 1000**4
        when "G" then 1000**3
        when "M" then 1000**2
        when "K" then 1000**1
        else 1
        end

      size * multiplier
    else
      raise Error, "Invalid memory format: #{memory_string.inspect}"
    end
  end

  class Resource
    attr_reader :api, :plural

    def initialize(plural, version: "v1", group: nil)
      @api = group ? "/apis/#{group}/#{version}" : "/api/#{version}"
      @plural = plural
    end

    def list(namespace: nil, params: {})
      path = namespace ? "#{@api}/namespaces/#{namespace}/#{@plural}" : "#{@api}/#{@plural}"

      response = Kubernetes.get(path, params)
      JSON.parse(response.body)
    end

    def get(name, namespace:)
      path = "#{@api}/namespaces/#{namespace}/#{@plural}/#{name}"
      response = Kubernetes.get(path, {})
      JSON.parse(response.body)
    end

    def get!(name, namespace:)
      response = get(name, namespace:)
      raise Error, "Resource #{@plural}/#{name} in namespace #{namespace} not found" if response["code"] == 404

      response
    end

    def exists?(name, namespace:)
      response = get(name, namespace:)
      response["code"] != 404
    end

    def create(params)
      namespace = params.dig("metadata", "namespace")
      raise Error, "namespace missing in metadata: #{params}" unless namespace

      path = "#{@api}/namespaces/#{namespace}/#{@plural}"
      response = Kubernetes.post(path, params)
      JSON.parse(response.body)
    end

    def update(params)
      namespace = params.dig("metadata", "namespace")
      raise Error, "namespace missing in metadata: #{params}" unless namespace

      name = params.dig("metadata", "name")
      raise Error, "name missing in metadata: #{params}" unless name

      path = "#{@api}/namespaces/#{namespace}/#{@plural}/#{name}"
      response = Kubernetes.put(path, params)
      JSON.parse(response.body)
    end

    def apply(params)
      namespace = params.dig("metadata", "namespace")
      raise Error, "namespace missing in metadata: #{params}" unless namespace

      name = params.dig("metadata", "name")
      raise Error, "name missing in metadata: #{params}" unless name

      params["metadata"].delete("managedFields")

      query_string = "fieldManager=#{Kubernetes.field_manager}&fieldValidation=Strict&force=true"
      path = "#{@api}/namespaces/#{namespace}/#{@plural}/#{name}?#{query_string}"

      response = Kubernetes.apply_patch(path, params)
      raise Error, "Apply failed: #{response.code} #{response.body}" unless response.code.start_with?("2")

      JSON.parse(response.body)
    end

    def patch(name, namespace:, subresource: nil, params: {})
      path = "#{@api}/namespaces/#{namespace}/#{@plural}/#{name}"
      path += "/#{subresource}" if subresource
      response = Kubernetes.merge_patch(path, params)
      raise Error, "Patch failed: #{response.code} #{response.body}" unless response.code.start_with?("2")

      JSON.parse(response.body)
    end

    def delete(name, namespace:)
      path = "#{@api}/namespaces/#{namespace}/#{@plural}/#{name}"
      response = Kubernetes.delete(path)
      JSON.parse(response.body)
    end

    def watch(namespace: nil, resource_version: nil)
      params = { watch: 1, resourceVersion: resource_version, allowWatchBookmarks: true }
      path = namespace ? "#{@api}/namespaces/#{namespace}/#{@plural}" : "#{@api}/#{@plural}"

      loop do
        Kubernetes.get(path, params) do |response|
          raise Error, "Watch failed: #{response.code} #{response.message}" unless response.is_a?(Net::HTTPOK)

          buffer = +""

          response.read_body do |chunk|
            while (index = chunk.index("\n"))
              line = buffer + chunk.slice!(0, index)
              chunk.slice!(0) # remove the newline

              event = JSON.parse(line)

              if event["type"] == "ERROR" && event.dig("object", "code") == 410
                message = event.dig("object", "message")
                # TODO: more graceful handling of expired watches, this approach is good enough for now
                # since we don't have any important logic around DELETE events which can go missing here.
                abort "ERROR: Watch expired: #{message}, aborting process to allow pod restart"
              end

              # Don't bother the caller with bookmark events, we only use them for resourceVersion updates
              yield event unless event["type"] == "BOOKMARK"

              new_resource_version = event.dig("object", "metadata", "resourceVersion")
              params[:resourceVersion] = new_resource_version if new_resource_version

              buffer = +""
            end

            buffer << chunk
          end
        end
      rescue Error, *TRANSIENT_NET_ERRORS => e
        LOGGER.error "class=Kubernetes::Resource message=watch-error error_class=#{e.class} error_message=#{e.message}"
        sleep 5
        retry
      end
    end
  end

  class Connection
    attr_reader :http

    DEFAULT_HEADERS = {
      "Accept" => "application/json",
      "Content-Type" => "application/json",
    }.freeze

    def initialize(http:, token:)
      @http = http
      @headers = token ? DEFAULT_HEADERS.merge("Authorization" => "Bearer #{token}") : DEFAULT_HEADERS
    end

    def get(path, params = {}, &)
      path += "?#{URI.encode_www_form(params)}" unless params.empty?
      request = Net::HTTP::Get.new(path, @headers)

      # watch requests need long timeouts to prevent timing out on empty resources
      initial_timeout = http.read_timeout
      http.read_timeout = 1.year if block_given?

      response = http.request(request, &)

      http.read_timeout = initial_timeout

      response
    end

    def post(path, params = {})
      request = Net::HTTP::Post.new(path, @headers)
      request.body = params.to_json unless params.empty?

      http.request(request)
    end

    def apply_patch(path, params = {})
      headers = @headers.merge("Content-Type" => "application/apply-patch+yaml")
      request = Net::HTTP::Patch.new(path, headers)
      request.body = params.to_json unless params.empty?

      http.request(request)
    end

    def merge_patch(path, params = {})
      headers = @headers.merge("Content-Type" => "application/merge-patch+json")
      request = Net::HTTP::Patch.new(path, headers)
      request.body = params.to_json unless params.empty?

      http.request(request)
    end

    def put(path, params = {})
      request = Net::HTTP::Put.new(path, @headers)
      request.body = params.to_json unless params.empty?

      http.request(request)
    end

    def delete(path, params = {})
      path += "?#{URI.encode_www_form(params)}" unless params.empty?
      request = Net::HTTP::Delete.new(path, @headers)
      http.request(request)
    end

    def active?
      http.active?
    end

    def closed?
      !http.active?
    end

    def restart
      close
      http.start
    end

    def close
      http.finish if http.active?
    end
  end

  class << self
    def connection_pool
      @connection_pool ||= NonReentrantConnectionPool.new { build_connection }
    end

    def get(path, params = {}, &)
      request(:get, path, params, &)
    end

    def post(path, params = {})
      request(:post, path, params)
    end

    def apply_patch(path, params = {})
      request(:apply_patch, path, params)
    end

    def merge_patch(path, params = {})
      request(:merge_patch, path, params)
    end

    def put(path, params = {})
      request(:put, path, params)
    end

    def delete(path)
      request(:delete, path)
    end

    def configmaps
      @configmaps ||= Resource.new("configmaps")
    end

    def deployments
      @deployments ||= Resource.new("deployments", group: "apps")
    end

    def statefulsets
      @statefulsets ||= Resource.new("statefulsets", group: "apps")
    end

    def secrets
      @secrets ||= Resource.new("secrets")
    end

    def services
      @services ||= Resource.new("services")
    end

    private

    STANDARD_ERROR_AND_MAYBE_IRB_ABORT = [StandardError, defined?(IRB::Abort) && IRB::Abort].compact.freeze

    def request(method, path, params = {}, &)
      connection_pool.with do |connection|
        unless connection.active?
          LOGGER.debug "class=Kubernetes message=restarting-connection"
          connection.restart
        end
        LOGGER.debug "class=Kubernetes method=#{method.upcase} path=#{path}"
        connection.send(method, path, params, &)
      rescue *STANDARD_ERROR_AND_MAYBE_IRB_ABORT
        connection_pool.discard(connection)
        raise
      end
    end

    def build_connection
      if ENV["KUBERNETES_SERVICE_HOST"]
        in_cluster_connection
      else
        kubeconfig_connection
      end
    end

    # In-cluster (ServiceAccount)
    def in_cluster_connection
      host = ENV.fetch("KUBERNETES_SERVICE_HOST")
      port = Integer(ENV["KUBERNETES_SERVICE_PORT_HTTPS"] || ENV["KUBERNETES_SERVICE_PORT"] || 443)

      service_account_path = "/var/run/secrets/kubernetes.io/serviceaccount"
      token_path = File.join(service_account_path, "token")
      ca_path = File.join(service_account_path, "ca.crt")

      token = File.read(token_path).strip if File.file?(token_path)

      http = Net::HTTP.new(host, port)
      configure_timeouts(http)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.ca_file = ca_path if File.file?(ca_path)
      http.start

      Connection.new(http:, token:)
    end

    # Out-of-cluster (KUBECONFIG)
    def kubeconfig_connection
      paths = ENV["KUBECONFIG"].to_s.split(":").push(File.join(Dir.home, ".kube", "config"))
      kubeconfig_path = paths.find { |path| File.file?(path) }

      raise Error, "KUBECONFIG not found" unless kubeconfig_path

      config = YAML.safe_load_file(kubeconfig_path)
      current_context = config["current-context"]
      raise Error, "No current-context set in KUBECONFIG" unless current_context

      context = kubeconfig_by_name(config["contexts"], current_context, "context")
      raise Error, "Context #{current_context.inspect} not found in KUBECONFIG" unless context

      cluster = kubeconfig_by_name(config["clusters"], context.fetch("cluster"), "cluster")
      user = kubeconfig_by_name(config["users"], context.fetch("user"), "user")

      server = cluster.fetch("server")
      uri = URI(server)
      host = uri.host
      port = uri.port || (uri.scheme == "https" ? 443 : 80)

      http = Net::HTTP.new(host, port)
      configure_timeouts(http)
      http.use_ssl = (uri.scheme == "https")

      if http.use_ssl?
        if cluster["insecure-skip-tls-verify"]
          http.verify_mode = OpenSSL::SSL::VERIFY_NONE
        else
          http.verify_mode = OpenSSL::SSL::VERIFY_PEER
          store = OpenSSL::X509::Store.new
          store.set_default_paths

          if (ca_file = cluster["certificate-authority"])
            store.add_file(File.expand_path(ca_file, File.dirname(path)))
          elsif (ca_data = cluster["certificate-authority-data"])
            cert_pem = Base64.decode64(ca_data)
            store.add_cert(OpenSSL::X509::Certificate.new(cert_pem))
          end

          http.cert_store = store
        end

        # Optional mTLS from user credentials
        if user && (user["client-certificate"] || user["client-certificate-data"])
          cert_pem =
            if user["client-certificate-data"]
              Base64.decode64(user["client-certificate-data"])
            else
              File.read(File.expand_path(user["client-certificate"], File.dirname(path)))
            end

          key_pem =
            if user["client-key-data"]
              Base64.decode64(user["client-key-data"])
            elsif user["client-key"]
              File.read(File.expand_path(user["client-key"], File.dirname(path)))
            end

          http.cert = OpenSSL::X509::Certificate.new(cert_pem) if cert_pem
          http.key = OpenSSL::PKey.read(key_pem) if key_pem
        end
      end

      http.start

      token =
        if user.nil?
          nil
        elsif user.key?("token")
          user["token"]
        elsif user.key?("tokenFile")
          File.read(user["tokenFile"]).strip
        elsif user.key?("exec")
          raise Error, "kubeconfig exec based credential handling is out of scope for this project"
        end

      Connection.new(http:, token:)
    end

    # Helpers

    def kubeconfig_by_name(entries, name, key)
      return nil unless entries && name

      found = entries.find { |e| e["name"] == name }
      found&.fetch(key, nil)
    end

    def configure_timeouts(http)
      http.keep_alive_timeout = 75
      http.open_timeout = 10
      http.read_timeout = 5
      http.write_timeout = 10
    end
  end
end
