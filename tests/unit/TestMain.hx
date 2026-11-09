package;

import utest.Runner;
import utest.ui.common.PackageResult;
import utest.ui.text.PrintReport;

class TestMain {
  public static function main() {
    var runner = new Runner();
    runner.addCase(new LoincTest());
    runner.addCase(new SanitizerTest());
    runner.addCase(new CanonicalTest());
    runner.addCase(new OrderValidatorTest());
    runner.addCase(new ConfigTest());
    runner.addCase(new ErrorMappingTest());
    runner.addCase(new LogTest());
    runner.addCase(new GuardTest());
    runner.addCase(new CatalogTest());
    runner.addCase(new WebhookTest());
    runner.addCase(new LisCoreTest());
    runner.addCase(new OrdersLockTest());
    runner.addCase(new ReconcilerTest());

    var report = new PrintReport(runner);
    // Registered after the report so results are printed first; a failure must fail the build.
    var aggregator = new utest.ui.common.ResultAggregator(runner, true);
    aggregator.onComplete.add(function(result:PackageResult) {
      if (!result.stats.isOk) {
        Sys.exit(1);
      }
    });
    runner.run();
  }
}

