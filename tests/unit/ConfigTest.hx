package;

import utest.Test;
import utest.Assert;
import core.Config;
import platform.Platform.IEnv;
import core.LisError.LisError;

class MockEnv implements IEnv {
  private var map:Map<String, String>;
  public function new(map:Map<String, String>) {
    this.map = map;
  }
  public function get(name:String):Null<String> {
    return map.get(name);
  }
}

class ConfigTest extends Test {
  public function testMissingBaseUrlThrows() {
    var env = new MockEnv(new Map<String, String>());
    var threw = false;
    try {
      Config.resolve(null, env);
    } catch (e:Dynamic) {
      threw = true;
      var err:LisError = cast e;
      Assert.equals("VALIDATION_FAILED", err.code);
      Assert.equals("config.baseUrl", err.field);
    }
    Assert.isTrue(threw);
  }

  public function testEnvResolutionAndTrailingSlashStripping() {
    var envMap = new Map<String, String>();
    envMap.set("LIS_BASE_URL", "http://192.168.1.50:8322///");
    envMap.set("LIS_API_KEY", "secret123");
    var env = new MockEnv(envMap);

    var conf = Config.resolve(null, env);
    Assert.equals("http://192.168.1.50:8322", conf.baseUrl);
    Assert.equals("secret123", conf.apiKey);
    Assert.equals(8000, conf.timeoutMs);
    Assert.equals("reject", conf.catalog.unknownTestPolicy);
  }
}

