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
      @debugger = Debugger.new

      @debugger.on_trace do |trace|
        puts "hey there #{trace[:result]}"
      end
    end

    def call(env)
      # For now, all websocket connections are assumed to be a debug connection
      if Faye::WebSocket.websocket?(env)
        ws = create_websocket(env)

        # Return async Rack response
        ws.rack_response
      elsif env["REQUEST_PATH"] == "/debug"
        expr = Rack::Request.new(env).params["expr"] || "n * 10"

        app = Proc.new do |env|
            ['200', {'Content-Type' => 'text/plain'}, [@debugger.retro_eval(expr)]]
        end

        app.call(env)
      else
        session = @debugger.new_session
        env["debug_session"] = session
        @app.call(env)
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

          result = {}

          if data["method"] == "test"
            response = {
              id: 1,
              result: result
            }
          end

          ws.send(response.to_json)
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

      ws
    end
  end
end
