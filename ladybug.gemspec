Gem::Specification.new do |s|
  s.name        = 'ladybug'
  s.version     = '0.1.3'
  s.date        = '2018-01-28'
  s.summary     = "Ladybug"
  s.description = "Debug Ruby code using Chrome Devtools"
  s.authors     = ["Geoffrey Litt"]
  s.email       = 'gklitt@gmail.com'
  s.files       = Dir.glob("lib/**/*") + %w(README.md)
  s.homepage    = 'http://rubygems.org/gems/ladybug'
  s.license     = 'MIT'

  s.add_runtime_dependency "faye-websocket", "~> 0.10"
  s.add_runtime_dependency "parser", "~> 2.4"
  s.add_runtime_dependency "memoist", "~> 0.14"
end
