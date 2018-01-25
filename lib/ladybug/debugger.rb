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

    # Given a filename and line number of a requested breakpoint,
    # give the line number of the next possible breakpoint.
    #
    # A breakpoint can be set at the beginning of any single statement.
    # (more details in #line_numbers_with_code)
    def get_possible_breakpoints(filename, line_number)
      code = File.read(filename)
      parsed = Parser::CurrentRuby.parse(code)
      next_possible_line =
        line_numbers_with_code(parsed).sort.find { |line| line >= line_number }

      next_possible_line.nil? ? [] : [next_possible_line]
    end

    private

    def trace_func
      @step_over_file = nil

      proc { |event, filename, line_number, id, binding, klass, *rest|
        # This check is called a lot so perhaps worth making faster,
        # but might not matter much with small number of breakpoints in practice
        breakpoint_hit = @breakpoints.find do |bp|
          bp[:filename] == filename && bp[:line_number] == line_number
        end

        break_on_step_over = (@step_over_file == filename)

        if breakpoint_hit || break_on_step_over
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
              @step_over_file = nil
              break
            when 'step_over'
              # todo: does "step over" really mean break in the same file,
              # or is there are a deeper meaning
              @step_over_file = filename
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

    # A breakpoint can be set at the beginning of any node where there is no
    # begin (i.e. multi-line) node anywhere under the node
    #
    # Todo: memoizing the child node types of each node in our tree
    # should make this a lot faster
    def line_numbers_with_code(ast)
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
          flat_map { |child| line_numbers_with_code(child) }.
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
