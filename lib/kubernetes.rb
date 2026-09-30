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
#   Kubernetes.deployments.watch(namespace: "default") do |event|
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

  # OpenSSL 3 reports a connection closed mid stream without a TLS close_notify, eg. by an API server shutting down or a
  # load balancer dropping it, as an SSLError rather than an EOFError. Other SSLErrors aren't retried, like failing
  # certificate verification or the same EOF during the handshake, which a proxy rejecting every connection also causes.
  SSL_READ_UNEXPECTED_EOF = Module.new do
    def self.===(error) = error.is_a?(OpenSSL::SSL::SSLError) && error.message.start_with?("SSL_read: unexpected eof")
  end

  TRANSIENT_NET_ERRORS = [
    EOFError,
    IOError,
    Errno::ECONNREFUSED,
    Errno::ECONNRESET,
    Errno::EHOSTUNREACH,
    Errno::ENETUNREACH,
    Errno::EPIPE,
    Errno::ETIMEDOUT,
    Errno::EBADF,
    Net::OpenTimeout,
    Net::ReadTimeout,
    Net::WriteTimeout,
    Net::HTTPBadResponse,
    SSL_READ_UNEXPECTED_EOF,
  ].freeze

  # Watch requests are ended by the server after this long (timeoutSeconds) and then resumed, which also bounds how long
  # a connection that died without being closed can go unnoticed. Bookmarks can't serve that purpose as the API server
  # doesn't guarantee sending any.
  WATCH_TIMEOUT = 5.minutes

  # Watches stream the current state again this often, which lets consumers retry events whose handling failed
  WATCH_RESYNC_INTERVAL = 10.minutes

  # Returns the memory size in bytes. The CRD only admits whole numbers of Mi or Gi.
  # https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/#meaning-of-memory
  def self.parse_memory(memory_string)
    case memory_string
    when /\A(\d+)(Mi|Gi)\z/
      # Base 10 since Integer() takes a leading zero, eg. 08Gi, for an octal number
      size = Integer(Regexp.last_match(1), 10)
      unit = Regexp.last_match(2)

      multiplier =
        case unit
        when "Gi" then 1024**3
        when "Mi" then 1024**2
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

    # Returns the resource, or the Status object of a 404 response. Other errors raise, like the other methods do.
    def get(name, namespace:)
      path = "#{@api}/namespaces/#{namespace}/#{@plural}/#{name}"
      response = Kubernetes.get(path, {})
      unless response.code.start_with?("2") || response.code == "404"
        raise Error, "Get #{@plural}/#{name} in namespace #{namespace} failed: #{response.code} #{response.body}"
      end

      JSON.parse(response.body)
    end

    def get!(name, namespace:)
      response = get(name, namespace:)
      raise Error, "Get #{@plural}/#{name} in namespace #{namespace} failed: #{response['code']} #{response['message']}" if response["kind"] == "Status"

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
      raise Error, "Create failed: #{response.code} #{response.body}" unless response.code.start_with?("2")

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
      raise Error, "Delete failed: #{response.code} #{response.body}" unless response.code.start_with?("2")

      JSON.parse(response.body)
    end

    # Yields the ADDED, MODIFIED and DELETED events of the collection until the process exits. The current state comes
    # first, as ADDED events streamed by the watch itself, so no separate list request is needed:
    # https://kubernetes.io/docs/reference/using-api/api-concepts/#streaming-lists
    #
    # Interrupted watches resume from the last resource version, backing off exponentially unless the stream delivered
    # events. Once that resource version has expired (410 Gone), and every WATCH_RESYNC_INTERVAL, the current state is
    # streamed afresh and followed by DELETED events for objects which disappeared in the meantime. Those only carry the
    # apiVersion, kind and the name, namespace and uid metadata. Consumers hence see every change, but must tolerate
    # repeated ADDED events.
    #
    # Exceptions raised by the block propagate to the caller rather than being mistaken for a broken connection, since
    # resuming would replay the same event.
    def watch(namespace: nil, &handler)
      path = namespace ? "#{@api}/namespaces/#{namespace}/#{@plural}" : "#{@api}/#{@plural}"
      # uid => what identifies the object, to tell which objects disappeared while the current state wasn't watched
      known_objects = {}
      remember = lambda do |object|
        known_objects[object.dig("metadata", "uid")] = {
          "apiVersion" => object["apiVersion"],
          "kind" => object["kind"],
          "metadata" => object.fetch("metadata").slice("name", "namespace", "uid"),
        }
      end
      resource_version = nil
      resynced_at = Time.now
      retry_delay = 1

      loop do
        resource_version = nil if Time.now - resynced_at > WATCH_RESYNC_INTERVAL

        params = { watch: 1, allowWatchBookmarks: true, timeoutSeconds: WATCH_TIMEOUT.to_i }
        if resource_version
          params[:resourceVersion] = resource_version
        else
          params.merge!(sendInitialEvents: true, resourceVersionMatch: "NotOlderThan", resourceVersion: "")
          resynced_at = Time.now
        end
        # The initial state is buffered until the bookmark which ends it and provides the resume point. Handling time counts
        # towards timeoutSeconds, so handling the events as they arrive could end the watch before the resume point is known.
        initial_events = resource_version ? nil : []
        status = nil
        status_message = nil
        streamed = false
        handler_failed = false
        handle = lambda do |event|
          handler.call(event)
        rescue StandardError
          handler_failed = true
          raise
        end

        begin
          Kubernetes.get(path, params) do |response|
            status = response.code
            unless response.is_a?(Net::HTTPOK)
              status_message = response.body
              next
            end

            buffer = +""

            response.read_body do |chunk|
              while (index = chunk.index("\n"))
                line = buffer + chunk.slice!(0, index)
                chunk.slice!(0) # remove the newline
                buffer = +""

                event = JSON.parse(line)
                type = event.fetch("type")
                object = event.fetch("object")

                if type == "ERROR"
                  # The server ends the stream after an error, eg. 410 Gone once resource_version has expired
                  status = object.fetch("code").to_s
                  status_message = object["message"]
                  next
                end
                streamed = true

                if type == "BOOKMARK"
                  initial_events_end = object.dig("metadata", "annotations", "k8s.io/initial-events-end") == "true"
                  # While the initial state is streamed only the bookmark which ends it is a resume point
                  next if initial_events && !initial_events_end

                  resource_version = object.dig("metadata", "resourceVersion")
                  next unless initial_events

                  initial_uids = initial_events.map { |initial_event| initial_event.dig("object", "metadata", "uid") }
                  vanished_uids = known_objects.keys - initial_uids
                  initial_events.each do |initial_event|
                    remember.call(initial_event.fetch("object"))
                    handle.call(initial_event)
                  end
                  vanished_uids.each { |uid| handle.call({ "type" => "DELETED", "object" => known_objects.delete(uid) }) }
                  initial_events = nil
                elsif initial_events
                  # The initial ADDED events aren't ordered by resource version, so they can't serve as resume points
                  initial_events << event
                else
                  if type == "DELETED"
                    known_objects.delete(object.dig("metadata", "uid"))
                  else
                    remember.call(object)
                  end
                  resource_version = object.dig("metadata", "resourceVersion")
                  handle.call(event)
                end
              end

              buffer << chunk
            end
          end

          case status
          when "200"
            # The server ended the watch after timeoutSeconds, resume (or start over if the initial state was incomplete)
          when "410"
            LOGGER.info "class=Kubernetes::Resource message=watch-expired plural=#{@plural}, streaming the current state afresh"
            resource_version = nil
          when "429", /\A5/
            LOGGER.warn "class=Kubernetes::Resource message=watch-failed plural=#{@plural} status=#{status} " \
                        "status_message=#{status_message}"
          else
            raise Error, "Watch of #{@plural} failed with status #{status}: #{status_message}"
          end
        rescue *TRANSIENT_NET_ERRORS => e
          raise if handler_failed

          LOGGER.warn "class=Kubernetes::Resource message=watch-interrupted plural=#{@plural} error_class=#{e.class} " \
                      "error_message=#{e.message}"
        end

        # Only a stream which delivered events proves the connection healthy, eg. an API server shutting down might accept
        # watches only to end them right away
        if streamed
          retry_delay = 1
        else
          sleep retry_delay
          retry_delay = [retry_delay * 2, 30].min
        end
      end
    end
  end

  class Connection
    attr_reader :http

    DEFAULT_HEADERS = {
      "Accept" => "application/json",
      "Content-Type" => "application/json",
    }.freeze

    def initialize(http:, token: nil, token_path: nil)
      @http = http
      @token = token
      @token_path = token_path
    end

    # A token_path is read for every request since the kubelet rotates projected service account tokens
    def headers
      token = @token_path ? File.read(@token_path).strip : @token
      token ? DEFAULT_HEADERS.merge("Authorization" => "Bearer #{token}") : DEFAULT_HEADERS
    end

    def get(path, params = {}, &)
      path += "?#{URI.encode_www_form(params)}" unless params.empty?
      request = Net::HTTP::Get.new(path, headers)

      # Watch requests stay silent for long periods on quiet resources, but are ended by the server after WATCH_TIMEOUT
      initial_timeout = http.read_timeout
      http.read_timeout = WATCH_TIMEOUT + 30.seconds if block_given?

      response = http.request(request, &)

      http.read_timeout = initial_timeout

      response
    end

    def post(path, params = {})
      request = Net::HTTP::Post.new(path, headers)
      request.body = params.to_json unless params.empty?

      http.request(request)
    end

    def apply_patch(path, params = {})
      request = Net::HTTP::Patch.new(path, headers.merge("Content-Type" => "application/apply-patch+yaml"))
      request.body = params.to_json unless params.empty?

      http.request(request)
    end

    def merge_patch(path, params = {})
      request = Net::HTTP::Patch.new(path, headers.merge("Content-Type" => "application/merge-patch+json"))
      request.body = params.to_json unless params.empty?

      http.request(request)
    end

    def put(path, params = {})
      request = Net::HTTP::Put.new(path, headers)
      request.body = params.to_json unless params.empty?

      http.request(request)
    end

    def delete(path, params = {})
      path += "?#{URI.encode_www_form(params)}" unless params.empty?
      request = Net::HTTP::Delete.new(path, headers)
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

    def events
      @events ||= Resource.new("events")
    end

    def pods
      @pods ||= Resource.new("pods")
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
      rescue *STANDARD_ERROR_AND_MAYBE_IRB_ABORT => e
        transient =
          case e
          when *TRANSIENT_NET_ERRORS then true
          else false
          end
        Sentry.capture_exception(e, level: transient ? :warning : :error)
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

      http = Net::HTTP.new(host, port)
      configure_timeouts(http)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.ca_file = ca_path if File.file?(ca_path)
      http.start

      Connection.new(http:, token_path: (token_path if File.file?(token_path)))
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
            store.add_file(File.expand_path(ca_file, File.dirname(kubeconfig_path)))
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
              File.read(File.expand_path(user["client-certificate"], File.dirname(kubeconfig_path)))
            end

          key_pem =
            if user["client-key-data"]
              Base64.decode64(user["client-key-data"])
            elsif user["client-key"]
              File.read(File.expand_path(user["client-key"], File.dirname(kubeconfig_path)))
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
