/**
 * Probe #2: find out WHY Driver.create() returns null.
 *
 * We already know:
 *   - normal app process  -> Driver.create() === null
 *   - `aa test` test process -> Driver.create() === null (probe #1)
 *   - docs say only `aa test`-launched test HAPs may use UiTest, APL must be normal
 *   - our app runs in SELinux domain u:r:debug_hap:s0
 *
 * This probe reports the test process's own SELinux domain, uid, and re-checks
 * the driver, so we can tell whether the domain (debug_hap) is the blocker.
 */
import { describe, it, expect } from '@ohos/hypium';
import { Driver, ON, Component } from '@ohos.UiTest';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

const DOMAIN = 0x1234;
const TAG = 'DshUiTestProbe';

function readTextFile(path: string): string {
  try {
    const f = fs.openSync(path, fs.OpenMode.READ_ONLY);
    const buf = new ArrayBuffer(256);
    const len = fs.readSync(f.fd, buf);
    fs.closeSync(f);
    const bytes = new Uint8Array(buf, 0, len);
    return util.TextDecoder.create('utf-8').decodeToString(bytes).trim();
  } catch (e) {
    return 'ERR:' + (e as Error).message;
  }
}

export default function uiTestProbeTest() {
  describe('uiTestProbe', () => {
    it('probeDriverCapability', 0, async () => {
      let report = '';

      // 1. who are we? (SELinux domain + uid decide whether the system lets us talk to UiTestKit)
      report += 'selinux=' + readTextFile('/proc/self/attr/current') + ';';
      report += 'uid=' + readTextFile('/proc/self/status').split('\n')
        .filter((line: string) => line.startsWith('Uid:'))[0] + ';';

      // 2. driver, again
      try {
        const driver: Driver = Driver.create();
        report += 'driver=' + (driver === null ? 'NULL' : 'OK') + ';';

        if (driver !== null) {
          try {
            const all: Array<Component> = await driver.findComponents(ON.clickable(true));
            report += 'clickableAll=' + all.length + ';';
          } catch (findErr) {
            report += 'findAllErr=' + (findErr as Error).message + ';';
          }
          try {
            const browser: Array<Component> = await driver.findComponents(
              ON.clickable(true).inWindow('com.huawei.hmos.browser'));
            report += 'browserClickable=' + browser.length + ';';
          } catch (browserErr) {
            report += 'browserErr=' + (browserErr as Error).message + ';';
          }
        }
      } catch (fatal) {
        report += 'fatal=' + (fatal as Error).message + ';';
      }

      hilog.info(DOMAIN, TAG, 'PROBE2_RESULT %{public}s', report);
      expect(report.length > 0).assertTrue();
    });
  });
}
