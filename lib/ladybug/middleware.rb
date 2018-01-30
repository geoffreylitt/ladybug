require 'faye/websocket'
require 'json'
require 'thread'
require 'pathname'

require 'ladybug/script_repository'
require 'ladybug/debugger'
require 'ladybug/object_manager'

# A Rack middleware that accepts a websocket connection from the Chrome
# Devtools UI and responds to requests, interacting with Ladybug::Debugger
module Ladybug
  class Middleware
    def initialize(app)
      @app = app
      @scripts = {}

      @script_repository = ScriptRepository.new
      @debugger =
        Debugger.new(preload_paths: @script_repository.all.map(&:path))
      @object_manager = ObjectManager.new
    end

    def call(env)
      puts "Debug in Chrome: chrome-devtools://devtools/bundled/inspector.html?ws=#{env['HTTP_HOST']}"

      # For now, all websocket connections are assumed to be a debug connection
      if Faye::WebSocket.websocket?(env)
        ws = create_websocket(env)

        # Return async Rack response
        ws.rack_response
      else
        @debugger.debug do
          @app.call(env)
        end
      end
    end

    private

    def create_websocket(env)
      ws = Faye::WebSocket.new(env)

      ws.on :message do |event|
        # The WebSockets library silently swallows errors.
        # Insert our own error handling for debugging purposes.

        begin
          data = JSON.parse(event.data)

          if data["method"] == "Page.getResourceTree"
            result = {
              frameTree: {
                frame: {
                  id: "123",
                  loaderId: "123",
                  mimeType: "text/plain",
                  securityOrigin: "http://localhost",
                  url: "http://localhost"
                },
                resources: @script_repository.all.map do |script|
                  {
                    mimeType: "text/plain",
                    type: "Script",
                    contentSize: script.size,
                    lastModified: script.last_modified_time.to_i,
                    url: script.virtual_url
                  }
                end
              }
            }
          elsif data["method"] == "Page.getResourceContent"
            result = {
              base64Encoded: false,
              content: "hello world"
            }
          elsif data["method"] == "Debugger.getScriptSource"
            script_id = data["params"]["scriptId"]
            path = @script_repository.find(id: script_id).path
            result = {
              scriptSource: File.new(path, "r").read
            }
          elsif data["method"] == "Debugger.getPossibleBreakpoints"
            script = @script_repository.find(id: data["params"]["start"]["scriptId"])

            # we convert to/from 0-indexed line numbers in Chrome
            # at the earliest/latest possible moment;
            # in this gem, lines are 1-indexed
            start_num = data["params"]["start"]["lineNumber"] + 1
            end_num = data["params"]["end"]["lineNumber"] + 1

            breakpoint_lines = @debugger.get_possible_breakpoints(
              path: script.path, start_num: start_num, end_num: end_num
            )

            locations = breakpoint_lines.map do |breakpoint_line|
              {
                scriptId: script.id,
                lineNumber: breakpoint_line - 1,
                columnNumber: 0
              }
            end

            result = { locations: locations }
          elsif data["method"] == "Debugger.setBreakpointByUrl"
            # Chrome gives us a virtual URL;
            # we need an absolute path to the file to match the API for set_trace_func
            script = @script_repository.find(virtual_url: data["params"]["url"])

            # DevTools gives us 0-indexed line numbers but
            # ruby uses 1-indexed line numbers
            line_number = data["params"]["lineNumber"]
            ruby_line_number = line_number + 1

            begin
              breakpoint = @debugger.set_breakpoint(
                filename: script.path,
                line_number: ruby_line_number
              )

              result = {
                breakpointId: breakpoint[:id],
                locations: [
                  {
                    scriptId: script.id,
                    # todo: need to get these +/- transformations centralized.
                    # a LineNumber class might be necessary...
                    lineNumber: breakpoint[:line_number] - 1,
                    columnNumber: data["params"]["columnNumber"],
                  }
                ]
              }
            rescue Debugger::InvalidBreakpointLocationError
              result = {}
            end
          elsif data["method"] == "Debugger.resume"
            # Synchronously just ack the command;
            # we'll async hear back from the main thread when execution resumes
            @debugger.resume
            result = {}
          elsif data["method"] == "Debugger.stepOver"
            # Synchronously just ack the command;
            # we'll async hear back from the main thread when execution resumes
            @debugger.step_over
            result = {}
          elsif data["method"] == "Debugger.stepInto"
            # Synchronously just ack the command;
            # we'll async hear back from the main thread when execution resumes
            @debugger.step_into
            result = {}
          elsif data["method"] == "Debugger.stepOut"
            # Synchronously just ack the command;
            # we'll async hear back from the main thread when execution resumes
            @debugger.step_out
            result = {}
          elsif data["method"] == "Debugger.evaluateOnCallFrame"
            evaluated = @debugger.evaluate(data["params"]["expression"])
            result = {
              result: @object_manager.serialize(evaluated)
            }
          elsif data["method"] == "Debugger.removeBreakpoint"
            @debugger.remove_breakpoint(data["params"]["breakpointId"])
            result = {}
          elsif data["method"] == "Runtime.getProperties"
            object = @object_manager.find(data["params"]["objectId"])

            result = {
              result: @object_manager.get_properties(object)
            }
          else
            result = {}
          end

          response = {
            id: data["id"],
            result: result
          }

          ws.send(response.to_json)

          # After we send a resource tree response, we need to send these
          # messages as well to get the files to show up
          if data["method"] == "Page.getResourceTree"
            @script_repository.all.each do |script|
              message = {
                method: "Debugger.scriptParsed",
                params: {
                  scriptId: script.id,
                  url: script.virtual_url,
                  startLine: 0,
                  startColumn: 0,
                  endLine: 100, #todo: really populate
                  endColumn: 100
                }
              }.to_json

              ws.send(message)
            end
          end
        rescue => e
          puts e.message
          puts e.backtrace

          raise e
        end
      end

      ws.on :close do |event|
        p [:close, event.code, event.reason]
        ws = nil
      end

      # Spawn a thread to handle messages from the main thread
      # and notify the client.

      @debugger.on_pause do |info|
        # Generate an object representing this scope
        # (this is here not in the debugger because the debugger
        #  shouldn't need to know about the requirement for a virtual object)
        virtual_scope_object =
          info[:local_variables].merge(info[:instance_variables])

        # Register the virtual object to give it an ID and hold a ref to it
        object_id = @object_manager.register(virtual_scope_object)

        script = @script_repository.find(absolute_path: info[:filename])

        # currently we don't support going into functions
        # that aren't in the path of our current app.
        if script.nil?
          puts "Debugger was paused on file outside of app: #{info[:filename]}"
          puts "ladybug currently only supports pausing in app files."
          @debugger.resume
        else
          location = {
            scriptId: script.id,
            lineNumber: info[:line_number] - 1,
            columnNumber: 0
          }

          msg_to_client = {
            method: "Debugger.paused",
            params: {
              callFrames: [
                {
                  location: location,
                  callFrameId: SecureRandom.uuid,
                  functionName: info[:label],
                  scopeChain: [
                    {
                      type: "local",
                      startLocation: location,
                      endLocation: location,
                      object: {
                        className: "Object",
                        description: "Object",
                        type: "object",
                        objectId: object_id
                      }
                    }
                  ],
                  url: script.virtual_url
                }
              ],
              hitBreakpoints: info[:breakpoint_id] ? [info[:breakpoint_id]] : [],
              reason: "other"
            }
          }

          ws.send(msg_to_client.to_json)
        end
      end

      @debugger.on_resume do
        msg_to_client = {
          method: "Debugger.resumed",
          params: {}
        }

        ws.send(msg_to_client.to_json)
      end

      ws
    end
  end
end
