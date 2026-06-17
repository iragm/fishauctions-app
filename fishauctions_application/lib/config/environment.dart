/// Environment configuration for different build variants
enum Environment { dev, staging, prod }

class EnvironmentConfig {
  static const Environment currentEnvironment = Environment.dev;

  static String get apiBaseUrl {
    switch (currentEnvironment) {
      case Environment.dev:
        return 'http://localhost:8000';
      case Environment.staging:
        return 'https://staging-api.fishauctions.com';
      case Environment.prod:
        return 'https://api.fishauctions.com';
    }
  }

  static bool get enableLogging => currentEnvironment == Environment.dev;
}
