class Pry
  # taken from irb
  # Implements tab completion for Readline in Pry
  module InputCompleter
    def self.start
      if Readline.respond_to?("basic_word_break_characters=")
        Readline.basic_word_break_characters = " \t\n\"\\'`><=;|&{("
      end

      Readline.completion_append_character = nil
      self
    end

    NUMERIC_REGEXP            = /^(-?(0[dbo])?[0-9_]+(\.[0-9_]+)?([eE]-?[0-9]+)?)\.([^.]*)$/
    ARRAY_REGEXP              = /^([^\]]*\])\.([^.]*)$/
    SYMBOL_REGEXP             = /^(:[^:.]*)$/
    SYMBOL_METHOD_CALL_REGEXP = /^(:[^:.]+)\.([^.]*)$/
    REGEX_REGEXP              = /^(\/[^\/]*\/)\.([^.]*)$/
    PROC_OR_HASH_REGEXP       = /^([^\}]*\})\.([^.]*)$/
    TOPLEVEL_LOOKUP_REGEXP    = /^::([A-Z][^:\.\(]*)$/
    CONSTANT_REGEXP           = /^([A-Z][A-Za-z0-9]*)$/
    CONSTANT_OR_METHOD_REGEXP = /^([A-Z].*)::([^:.]*)$/
    HEX_REGEXP                = /^(-?0x[0-9a-fA-F_]+)\.([^.]*)$/
    GLOBALVARIABLE_REGEXP     = /^(\$[^.]*)$/
    VARIABLE_REGEXP           = /^([^."].*)\.([^.]*)$/

    ReservedWords = [
      "BEGIN", "END",
      "alias", "and",
      "begin", "break",
      "case", "class",
      "def", "defined", "do",
      "else", "elsif", "end", "ensure",
      "false", "for",
      "if", "in",
      "module",
      "next", "nil", "not",
      "or",
      "redo", "rescue", "retry", "return",
      "self", "super",
      "then", "true",
      "undef", "unless", "until",
      "when", "while",
      "yield" ]

    Operators = [
      "%", "&", "*", "**", "+",  "-",  "/",
      "<", "<<", "<=", "<=>", "==", "===", "=~", ">", ">=", ">>",
      "[]", "[]=", "^", "!", "!=", "!~"
    ]

    # Return a new completion proc for use by Readline.
    # @param [Binding] input The current binding context.
    # @param [Array<String>] options The array of Pry commands.
    def self.call(input, options)
      custom_completions = options[:custom_completions] || []

      # if there are multiple contexts e.g. cd 1/2/3
      # get new target for 1/2 and find candidates for 3
      path, input = build_path(input)

      if path.call.empty?
        target = options[:target]
      else
        target, _ = Pry::Helpers::BaseHelpers.context_from_object_path(path.call, options[:pry])
        target = target.last
      end

      begin
        bind = target
        # Complete stdlib symbols
        case input
        when REGEX_REGEXP # Regexp
          receiver = $1
          message = Regexp.quote($2)
          candidates = Regexp.instance_methods.collect(&:to_s)
          select_message(path, receiver, message, candidates)
        when ARRAY_REGEXP # Array
          receiver = $1
          message = Regexp.quote($2)
          candidates = Array.instance_methods.collect(&:to_s)
          select_message(path, receiver, message, candidates)
        when PROC_OR_HASH_REGEXP # Proc or Hash
          receiver = $1
          message = Regexp.quote($2)
          candidates = Proc.instance_methods.collect(&:to_s)
          candidates |= Hash.instance_methods.collect(&:to_s)
          select_message(path, receiver, message, candidates)
        when SYMBOL_REGEXP # Symbol
          if Symbol.respond_to?(:all_symbols)
            sym        = Regexp.quote($1)
            candidates = Symbol.all_symbols.collect{|s| ":" << s.id2name}
            candidates.grep(/^#{sym}/)
          else
            []
          end
        when TOPLEVEL_LOOKUP_REGEXP # Absolute Constant or class methods
          receiver = $1
          candidates = Object.constants.collect(&:to_s)
          candidates.grep(/^#{receiver}/).collect{|e| "::" << e}
        when CONSTANT_REGEXP # Constant
          message = $1
          begin
            context = target.eval("self")
            context = context.class unless context.respond_to? :constants
            candidates = context.constants.collect(&:to_s)
          rescue
            candidates = []
          end
          candidates = candidates.grep(/^#{message}/).collect(&path)
        when CONSTANT_OR_METHOD_REGEXP # Constant or class methods
          receiver = $1
          message = Regexp.quote($2)
          begin
            candidates = eval("#{receiver}.constants.collect(&:to_s)", bind)
            candidates |= eval("#{receiver}.methods.collect(&:to_s)", bind)
          rescue RescuableException
            candidates = []
          end
          candidates.grep(/^#{message}/).collect{|e| receiver << "::" << e}
        when SYMBOL_METHOD_CALL_REGEXP # method call on a Symbol
          receiver = $1
          message = Regexp.quote($2)
          candidates = Symbol.instance_methods.collect(&:to_s)
          select_message(path, receiver, message, candidates)
        when NUMERIC_REGEXP
          # Numeric
          receiver = $1
          message = Regexp.quote($5)
          begin
            candidates = eval(receiver, bind).methods.collect(&:to_s)
          rescue RescuableException
            candidates = []
          end
          select_message(path, receiver, message, candidates)
        when HEX_REGEXP
          # Numeric(0xFFFF)
          receiver = $1
          message = Regexp.quote($2)
          begin
            candidates = eval(receiver, bind).methods.collect(&:to_s)
          rescue RescuableException
            candidates = []
          end
          select_message(path, receiver, message, candidates)
        when GLOBALVARIABLE_REGEXP # global
          regmessage = Regexp.new(Regexp.quote($1))
          candidates = global_variables.collect(&:to_s).grep(regmessage)
        when VARIABLE_REGEXP # variable
          receiver = $1
          message = Regexp.quote($2)

          gv = eval("global_variables", bind).collect(&:to_s)
          lv = eval("local_variables", bind).collect(&:to_s)
          cv = eval("self.class.constants", bind).collect(&:to_s)

          if (gv | lv | cv).include?(receiver) or /^[A-Z]/ =~ receiver && /\./ !~ receiver
            # foo.func and foo is local var. OR
            # Foo::Bar.func
            begin
              candidates = eval("#{receiver}.methods", bind).collect(&:to_s)
            rescue RescuableException
              candidates = []
            end
          else
            # func1.func2
            candidates = []
            ObjectSpace.each_object(Module){|m|
              begin
                name = m.name.to_s
              rescue RescuableException
                name = ""
              end
              next if name != "IRB::Context" and
              /^(IRB|SLex|RubyLex|RubyToken)/ =~ name

              # jruby doesn't always provide #instance_methods() on each
              # object.
              if m.respond_to?(:instance_methods)
                candidates.concat m.instance_methods(false).collect(&:to_s)
              end
            }
            candidates.sort!
            candidates.uniq!
          end
          select_message(path, receiver, message, candidates)
        when /^\.([^.]*)$/
          # Unknown(maybe String)
          receiver = ""
          message = Regexp.quote($1)
          candidates = String.instance_methods(true).collect(&:to_s)
          select_message(path, receiver, message, candidates)
        else
          candidates = eval(
            "methods | private_methods | local_variables | " \
              "self.class.constants | instance_variables",
            bind
          ).collect(&:to_s)

          if eval("respond_to?(:class_variables)", bind)
            candidates += eval("class_variables", bind).collect(&:to_s)
          end
          candidates = (candidates|ReservedWords|custom_completions).grep(/^#{Regexp.quote(input)}/)
          candidates.collect(&path)
        end
      rescue RescuableException
        []
      end
    end

    def self.select_message(path, receiver, message, candidates)
      candidates.grep(/^#{message}/).collect { |e|
        case e
        when /^[a-zA-Z_]/
          path.call(receiver + "." << e)
        when /^[0-9]/
        when *Operators
          #receiver + " " << e
        end
      }.compact
    end

    # build_path seperates the input into two parts: path and input.
    # input is the partial string that should be completed
    # path is a proc that takes an input and builds a full path.
    def self.build_path(input)

      # check to see if the input is a regex
      return proc {|i| i.to_s }, input if input[/\/\./]

      trailing_slash = input.end_with?('/')
      contexts = input.chomp('/').split(/\//)
      input = contexts[-1]

      path = proc do |i|
        p = contexts[0..-2].push(i).join('/')
        p += '/' if trailing_slash && !i.nil?
        p
      end

      return path, input
    end
  end
end
