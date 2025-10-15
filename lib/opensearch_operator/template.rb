class OpensearchOperator
  class Template
    def self.templates
      Dir.glob(File.join(__dir__, "..", "..", "templates", "*"))
        .each_with_object({}) do |path, hash|
          name = File.basename(path).split(".").first
          hash[name] = new(path)
        end.freeze
    end

    def self.[](name)
      templates.fetch(name)
    end

    def initialize(path)
      @path = path
      @template = File.read(path)
      @substitution_variables = @template.scan(/%\{(\w+)\}/).flatten.uniq.freeze
    end

    def render(variables)
      missing_vars = @substitution_variables - variables.keys.map(&:to_s)

      unless missing_vars.empty?
        raise ArgumentError, "Missing variables for template #{@path}: #{missing_vars.join(', ')}"
      end

      template = @template.dup
      variables.each do |key, value|
        template.gsub!("%{#{key}}", value.to_s)
      end

      if @path.end_with?(".yaml")
        YAML.safe_load(template)
      else
        template
      end
    rescue Psych::SyntaxError
      if respond_to?(:debugger)
        puts "Template rendered invalid YAML, entering debugger..."
        debugger
      end
      raise
    end
  end
end
