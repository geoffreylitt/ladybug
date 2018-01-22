Gem::Specification.new do |s|
  s.name        = 'ladybug'
  s.version     = '0.0.1.alpha'
  s.date        = '2018-01-21'
  s.summary     = "Ladybug"
  s.description = "Debug Ruby code using Chrome Devtools"
  s.authors     = ["Geoffrey Litt"]
  s.email       = 'gklitt@gmail.com'
  s.files       = ["lib/ladybug.rb"]
  s.homepage    = 'http://rubygems.org/gems/ladybug'
  s.license     = 'MIT'

  s.add_runtime_dependency "faye-websocket"
end
