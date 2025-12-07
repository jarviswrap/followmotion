Pod::Spec.new do |s|
  s.name         = 'followmotion'
  s.version      = '1.0.0'
  s.summary      = 'Global input plugin for macOS'
  s.description  = 'Global input listening and simulation on macOS.'
  s.homepage     = 'https://example.com'
  s.license      = { :type => 'MIT' }
  s.author       = { 'Author' => 'author@example.com' }
  s.source       = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.public_header_files = 'Classes/**/*.h'
  s.platform     = :osx, '10.14'
  s.requires_arc = true
  s.dependency   'FlutterMacOS'
  s.frameworks   = 'FlutterMacOS'
end