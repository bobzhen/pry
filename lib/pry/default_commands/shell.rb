class Pry
  module DefaultCommands

    Shell = Pry::CommandSet.new do

      command(/\.(.*)/, "All text following a '.' is forwarded to the shell.", :listing => ".<shell command>", :use_prefix => false) do |cmd|
        if cmd =~ /^cd\s+(.+)/i
          dest = $1
          begin
            Dir.chdir File.expand_path(dest)
          rescue Errno::ENOENT
            raise CommandError, "No such directory: #{dest}"
          end
        else
          Pry.config.system.call(output, cmd, _pry_)
        end
      end

      command "shell-mode", "Toggle shell mode. Bring in pwd prompt and file completion." do
        case _pry_.prompt
        when Pry::SHELL_PROMPT
          _pry_.pop_prompt
          _pry_.custom_completions = Pry::DEFAULT_CUSTOM_COMPLETIONS
        else
          _pry_.push_prompt Pry::SHELL_PROMPT
          _pry_.custom_completions = Pry::FILE_COMPLETIONS
          Readline.completion_proc = Pry::InputCompleter.build_completion_proc target,
          _pry_.instance_eval(&Pry::FILE_COMPLETIONS)
        end
      end
      alias_command "file-mode", "shell-mode"

      create_command "save-file", "Export to a file using content from the REPL."  do
        banner <<-USAGE
          Usage: save-file [OPTIONS] [METH]
          Save REPL content to a file.
          e.g: save-file -m my_method -m my_method2 ./hello.rb
          e.g: save-file -i 1..10 ./hello.rb
          e.g: save-file -c show-method ./my_command.rb
          e.g: save-file -f sample_file --lines 2..10 ./output_file.rb
        USAGE

        attr_accessor :content
        attr_accessor :file_name

        def setup
          self.content = ""
        end

        def options(opt)
          opt.on :m, :method, "Save a method's source.", true do |meth_name|
            meth = get_method_or_raise(meth_name, target, {})
            self.content << meth.source
          end
          opt.on :c, :command, "Save a command's source.", true do |command_name|
            command = find_command(command_name)
            self.content << command.block.source
          end
          opt.on :f, :file, "Save a file.", true do |file|
            self.content << File.read(File.expand_path(file))
          end
          opt.on :l, :lines, "Only save a subset of lines.", :optional => true, :as => Range, :default => 1..-1
          opt.on :i, :in, "Save entries from Pry's input expression history. Takes an index or range.", :optional => true,
          :as => Range, :default => -5..-1 do |range|
            input_expressions = _pry_.input_array[range] || []
            Array(input_expressions).each { |v| self.content << v }
          end
        end

        def process
          if args.empty?
            raise CommandError, "Must specify a file name."
          end

          self.file_name = File.expand_path(args.first)

          save_file
        end

        def save_file
          if self.content.empty?
            raise CommandError, "Found no code to save."
          end

          File.open(file_name, "w") do |f|
            if opts.present?(:lines)
              f.puts restrict_to_lines(content, opts[:l])
            else
              f.puts content
            end
          end
        end

        def restrict_to_lines(content, lines)
          line_range = one_index_range(lines)
          content.lines.to_a[line_range].join
        end
      end

      create_command "cat", "Show code from a file, Pry's input buffer, or the last exception." do
        banner <<-USAGE
          Usage: cat FILE
                 cat --ex [STACK_INDEX]
                 cat --in [INPUT_INDEX_OR_RANGE]

          cat is capable of showing part or all of a source file, the context of the
          last exception, or an expression from Pry's input history.

          cat --ex defaults to showing the lines surrounding the location of the last
          exception. Invoking it more than once travels up the exception's backtrace,
          and providing a number shows the context of the given index of the backtrace.
        USAGE

        def options(opt)
          opt.on :ex,        "Show the context of the last exception.", :optional => true, :as => Integer
          opt.on :i, :in,    "Show one or more entries from Pry's expression history.", :optional => true, :as => Range, :default => -5..-1

          opt.on :s, :start, "Starting line (defaults to the first line).", :optional => true, :as => Integer
          opt.on :e, :end,   "Ending line (defaults to the last line).", :optional => true, :as => Integer
          opt.on :l, :'line-numbers', "Show line numbers."
          opt.on :t, :type,  "The file type for syntax highlighting (e.g., 'ruby' or 'python').", true, :as => Symbol

          opt.on :f, :flood, "Do not use a pager to view text longer than one screen."
        end

        def process
          handler = case
            when opts.present?(:ex)
              method :process_ex
            when opts.present?(:in)
              method :process_in
            else
              method :process_file
            end

          output = handler.call do |code|
            code.code_type = opts[:type] || :ruby

            code.between(opts[:start] || 1, opts[:end] || -1).
              with_line_numbers(opts.present?(:'line-numbers') || opts.present?(:ex))
          end

          render_output(output, opts)
        end

        def process_ex
          window_size = Pry.config.default_window_size || 5
          ex = _pry_.last_exception

          raise CommandError, "No exception found." unless ex

          if opts[:ex].nil?
            bt_index = ex.bt_index
            ex.inc_bt_index
          else
            bt_index = opts[:ex]
          end

          ex_file, ex_line = ex.bt_source_location_for(bt_index)

          raise CommandError, "The given backtrace level is out of bounds." unless ex_file

          if RbxPath.is_core_path?(ex_file)
            ex_file = RbxPath.convert_path_to_full(ex_file)
          end

          set_file_and_dir_locals(ex_file)

          start_line = ex_line - window_size
          start_line = 1 if start_line < 1
          end_line = ex_line + window_size

          header = unindent <<-HEADER
            #{text.bold 'Exception:'} #{ex.class}: #{ex.message}
            --
            #{text.bold('From:')} #{ex_file} @ line #{ex_line} @ #{text.bold("level: #{bt_index}")} of backtrace (of #{ex.backtrace.size - 1}).

          HEADER

          code = yield(Pry::Code.from_file(ex_file).
                         between(start_line, end_line).
                         with_marker(ex_line))

          "#{header}#{code}"
        end

        def process_in
          normalized_range = absolute_index_range(opts[:i], _pry_.input_array.length)
          input_items = _pry_.input_array[normalized_range] || []

          zipped_items = normalized_range.zip(input_items).reject { |_, s| s.nil? || s == "" }

          unless zipped_items.length > 0
            raise CommandError, "No expressions found."
          end

          if zipped_items.length > 1
            contents = ""
            zipped_items.each do |i, s|
              contents << "#{text.bold(i.to_s)}:\n"
              contents << yield(Pry::Code(s).with_indentation(2)).to_s
            end
          else
            contents = yield(Pry::Code(zipped_items.first.last))
          end

          contents
        end

        def process_file
          file_name = args.shift

          unless file_name
            raise CommandError, "Must provide a filename, --in, or --ex."
          end

          file_name, line_num = file_name.split(':')
          set_file_and_dir_locals(file_name)

          code = yield(Pry::Code.from_file(file_name))

          if line_num
            code = code.around(line_num.to_i,
                               Pry.config.default_window_size || 7)
          end

          code
        end
      end
    end

  end
end

