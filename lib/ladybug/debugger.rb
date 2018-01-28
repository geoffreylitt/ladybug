# A simple debugger using set_trace_func
# Allows for external control while in a breakpoint

require 'parser/current'
Parser::Builders::Default.emit_lambda = true
Parser::Builders::Default.emit_procarg0 = true

module Ladybug
  class Debugger
    def initialize
      @breakpoints = []

      @to_main_thread = Queue.new
      @from_main_thread = Queue.new

      @on_pause = -> {}
      @on_resume = -> {}

      @line_numbers_cache = {}
    end

    def start
      RubyVM::InstructionSequence.compile_option = {
        trace_instruction: true
      }

      set_trace_func trace_func
    end

    def on_pause(&block)
      @on_pause = block
    end

    def on_resume(&block)
      @on_resume = block
    end

    def resume
      @to_main_thread.push({ command: 'continue' })
    end

    def step_over
      @to_main_thread.push({ command: 'step_over' })
    end

    def step_into
      @to_main_thread.push({ command: 'step_into' })
    end

    def step_out
      @to_main_thread.push({ command: 'step_out' })
    end

    def evaluate(expression)
      @to_main_thread.push({
        command: 'eval',
        arguments: {
          expression: expression
        }
      })

      # Block on eval, returns result
      @from_main_thread.pop
    end

    # returns a breakpoint ID
    def set_breakpoint(filename:, line_number:)


      breakpoint = {
        filename: filename,
        line_number: line_number,
        id: "filename:#{line_number}"
      }

      @breakpoints.push(breakpoint)

      breakpoint[:id]
    end

    def remove_breakpoint(breakpoint_id)
      filename, line_number = breakpoint_id.split(":")
      line_number = line_number.to_i

      @breakpoints.delete_if { |bp| bp[:id] == breakpoint_id }
    end

    # Given a filename line number range of a requested breakpoint,
    # give the line numbers of possible breakpoints.
    #
    # In practice, start and end number tend to be the same when
    # Chrome devtools is the client.
    #
    # A breakpoint can be set at the beginning of any Ruby statement.
    # (more details in #line_numbers_with_code)
    def get_possible_breakpoints(path:, start_num:, end_num:)
      (start_num..end_num).to_a & line_numbers_with_code(path)
    end

    private

    # remove ladybug code from a callstack and prepare it for comparison
    # this is a hack implemenetation for now, can be made better
    def clean(callstack)
      callstack.select { |frame| !frame.to_s.include? "ladybug" }.map(&:to_s)
    end

    def break?(callstack:)
      result = false
      current_callstack = Thread.current.backtrace_locations

      if @break == 'step_over'
        if clean(@breakpoint_callstack)[1] == clean(current_callstack)[1]
          puts "breaking on step over"
          result = true
        end
      elsif @break == 'step_into'
        if clean(@breakpoint_callstack) == clean(current_callstack)[1..-1]
          puts "breaking on step into"
          result = true
        end
      elsif @break == 'step_out'
        if clean(current_callstack) == clean(@breakpoint_callstack)[1..-1]
          puts "breaking on step out"
          result = true
        end
      end

      result
    end

    def trace_func
      proc { |event, filename, line_number, id, binding, klass, *rest|
        # This check is called a lot so perhaps worth making faster,
        # but might not matter much with small number of breakpoints in practice
        breakpoint_hit = @breakpoints.find do |bp|
          bp[:filename] == filename && bp[:line_number] == line_number
        end

        if breakpoint_hit ||
           break?(callstack: Thread.current.backtrace_locations)
           # break?(call_stack: Thread.current.backtrace_locations)
          local_variables =
            binding.local_variables.each_with_object({}) do |lvar, hash|
              hash[lvar] = binding.local_variable_get(lvar)
            end

          instance_variables =
            binding.eval("instance_variables").each_with_object({}) do |ivar, hash|
              hash[ivar] = binding.eval("instance_variable_get(:#{ivar})")
            end

          pause_info = {
            breakpoint_id: breakpoint_hit ? breakpoint_hit[:id] : nil,
            label: Kernel.caller_locations.first.base_label,
            local_variables: local_variables,
            instance_variables: instance_variables,
            filename: filename,
            line_number: line_number
            # call_frames: []

            # Call frames are pretty complicated...
            # call_frames: Kernel.caller_locations.first(3).map do |call_frame|
            #   {
            #     callFrameId: SecureRandom.uuid,
            #     functionName: call_frame.base_label,
            #     scopeChain: [
            #       {
            #         type: "local",
            #         startLocation: ,
            #         endLocation:
            #       }
            #     ],
            #     url: "#{"http://rails.com"}/#{filename}",
            #     this:
            #   }
            # end
          }

          @on_pause.call(pause_info)

          loop do
            # block until we get a command from the debugger thread
            message = @to_main_thread.pop

            case message[:command]
            when 'continue'
              @break = nil
              break
            when 'step_over'
              @break = 'step_over'
              @breakpoint_callstack = Thread.current.backtrace_locations
              break
            when 'step_into'
              @break = 'step_into'
              @breakpoint_callstack = Thread.current.backtrace_locations
              break
            when 'step_out'
              @break = 'step_out'
              @breakpoint_callstack = Thread.current.backtrace_locations
              break
            when 'eval'
              evaluated =
                begin
                  binding.eval(message[:arguments][:expression])
                rescue
                  nil
                end
              @from_main_thread.push(evaluated)
            end
          end

          # Notify the debugger thread that we've resumed
          @on_resume.call({})
        end
      }
    end

    # get valid breakpoint lines for a file, with a memoize cache
    # TODO: think about cache invalidation here;
    # when do we know we have to re-parse a file?
    # TODO: switch to memoist gem for concision
    def line_numbers_with_code(path)
      if !@line_numbers_cache.key?(path)
        code = File.read(path)
        ast = Parser::CurrentRuby.parse(code)
        result = single_statement_lines(ast)
        @line_numbers_cache[path] = result
      end

      @line_numbers_cache[path]
    end

    # A breakpoint can be set at the beginning of any node where there is no
    # begin (i.e. multi-line) node anywhere under the node
    #
    # Todo: memoizing the child node types of each node in our tree
    # could make this a lot faster;
    # for the moment we at least memoize on the file level so
    # we only have to go through this whole thing once
    def single_statement_lines(ast)
      child_types = deep_child_node_types(ast)

      if !child_types.include?(:begin) && !child_types.include?(:kwbegin)
        expr = ast.loc.expression

        if !expr.nil?
          expr.begin.line
        else
          nil
        end
      else
        ast.children.
          select { |child| child.is_a? AST::Node }.
          flat_map { |child| single_statement_lines(child) }.
          compact.
          uniq
      end
    end

    # Return all unique types of AST nodes under this node,
    # including the node itself
    def deep_child_node_types(ast)
      types = ast.children.flat_map do |child|
        deep_child_node_types(child) if child.is_a? AST::Node
      end.compact + [ast.type]

      types.uniq
    end
  end
end
