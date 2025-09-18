class OpensearchOperator
  class Template
    def self.templates
      Dir.glob(File.join(__dir__, "..", "..", "templates", "*.yaml"))
        .each_with_object({}) do |file, hash|
          name = File.basename(file, ".yaml")
          hash[name] = new(File.read(file))
        end.freeze
    end

    def self.[](name)
      templates.fetch(name)
    end

    def initialize(template)
      @template = template
      @substitution_variables = template.scan(/%\{(\w+)\}/).flatten.uniq.freeze
    end

    def render(variables)
      missing_vars = @substitution_variables - variables.keys.map(&:to_s)

      unless missing_vars.empty?
        raise ArgumentError, "Missing variables for template: #{missing_vars.join(', ')}"
      end

      new_template = @template.dup
      variables.each do |key, value|
        new_template.gsub!("%{#{key}}", value.to_s)
      end

      YAML.safe_load(new_template)
    end
  end
end
