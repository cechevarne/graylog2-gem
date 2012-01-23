$:.push File.expand_path("../lib", __FILE__)

# Maintain your gem's version:
require "graylog2/version"

# Describe your gem and declare its dependencies:
Gem::Specification.new do |s|
  s.name        = "graylog2"
  s.version     = Graylog2::VERSION
  s.authors     = ["Uses mainly code by Lennart Koopmann, modified by Lukas F. Hartmann"]
  s.email       = ["info@spaceship.io"]
  s.homepage    = "https://github.com/spaceship-io/graylog2-gem"
  s.summary     = "Access Graylog2 messages through a gem"
  s.description = "--"
  s.files = Dir["lib/**/*"]

  s.add_dependency "mongoid"
  s.add_dependency "tire"
end
