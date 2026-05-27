Pod::Spec.new do |s|
  s.name             = 'flipperlib'
  s.version          = '0.1.0'
  s.summary          = 'Flipper Zero native BLE plugin for macOS'
  s.description      = s.summary
  s.homepage         = 'https://github.com/apfxtech'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'apfxtech' => 'aperturefoxtechnology@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'FlutterMacOS'

  s.platform = :osx, '10.15'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
