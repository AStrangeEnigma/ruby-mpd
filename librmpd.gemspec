# -*- encoding: utf-8 -*-

Gem::Specification.new do |s|
  s.platform         = Gem::Platform::RUBY
  s.name             = "ruby-mpd"
  s.version          = "0.1.3"
  s.authors           = ["Blaž Hrastnik"]
  s.email             = ['speed.the.bboy@gmail.com']
  s.summary          = "Ruby client library for MPD"
  s.description      = "A simple yet powerful library for the Music Player Daemon, written in Ruby."

  s.has_rdoc         = true
  s.extra_rdoc_files = ['README.md']

  s.files         = `git ls-files`.split("\n")
  s.test_files    = `git ls-files -- {test,spec,features}/*`.split("\n")
  s.executables   = `git ls-files -- bin/*`.split("\n").map{ |f| File.basename(f) }
  s.require_paths = ["lib"]
end