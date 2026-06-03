Pod::Spec.new do |s|
  s.name             = 'unilitix_flutter'
  s.version          = '2.0.50'
  s.summary          = 'African-first mobile UX analytics for Flutter.'
  s.description      = 'Unilitix Flutter SDK — track sessions, screens, events and crashes.'
  s.homepage         = 'https://unilitix.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Unilitix' => 'support@unilitix.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'
  s.frameworks       = 'CoreTelephony', 'UIKit', 'Network'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }
  s.swift_version = '5.0'

  s.resource_bundles = { 'unilitix_flutter_privacy' => ['Resources/PrivacyInfo.xcprivacy'] }
end
