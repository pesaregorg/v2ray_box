#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint v2ray_box.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'v2ray_box'
  s.version          = '1.0.0'
  s.summary          = 'V2Ray VPN plugin for Flutter with dual-core support (Xray-core & sing-box)'
  s.description      = <<-DESC
A Flutter plugin for V2Ray VPN functionality supporting both Xray-core and sing-box engines.

Build Libbox.xcframework from the official SagerNet/sing-box repository
and place it in your app's ios/Frameworks/ directory.
LibXray.xcframework is used by the PacketTunnel extension target and should
be linked there (not in the v2ray_box pod target) to avoid duplicate Go symbols.
                       DESC
  s.homepage         = 'https://github.com/example/v2ray_box'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '15.0'
  
  # Core frameworks are NOT bundled with this plugin package.
  # Build/copy Libbox.xcframework into ios/Frameworks/ before pod install.
  s.vendored_frameworks = [
    'Frameworks/Libbox.xcframework'
  ]
  
  s.frameworks = 'NetworkExtension'
  s.libraries = 'resolv'
  
  s.pod_target_xcconfig = { 
    'DEFINES_MODULE' => 'YES', 
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'OTHER_LDFLAGS' => '-ObjC'
  }
  s.swift_version = '5.0'

  # Privacy manifest
  s.resource_bundles = {'v2ray_box_privacy' => ['Resources/PrivacyInfo.xcprivacy']}
end
