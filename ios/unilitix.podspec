Pod::Spec.new do |s|
  s.name             = 'unilitix'
  s.version          = '2.5.0'
  s.summary          = 'African-first mobile UX analytics for Flutter.'
  s.description      = 'Unilitix Flutter SDK — track sessions, screens, events and crashes.'
  s.homepage         = 'https://unilitix.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Unilitix' => 'support@unilitix.com' }
  s.source           = { :path => '.' }
  # Classes/UnilitixCore is UnilitixCore's sources, vendored by
  # scripts/sync-ios-core.sh (crash capture, screenshot drawing/encoding).
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  # UnilitixCore's minimum too (Package.swift: .iOS(.v13)).
  s.platform         = :ios, '13.0'
  s.frameworks       = 'CoreTelephony', 'UIKit', 'Network', 'CoreLocation', 'CoreGraphics', 'SwiftUI'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }
  s.swift_version = '5.0'

  s.resource_bundles = { 'unilitix_privacy' => ['Resources/PrivacyInfo.xcprivacy'] }
end
