import { WebPlugin } from '@capacitor/core';

import type { ARScannerPlugin, SupportResult, ScanResult } from './definitions';

export class ARScannerWeb extends WebPlugin implements ARScannerPlugin {
  async checkSupport(): Promise<SupportResult> {
    throw this.unavailable('AR support check is not available on web.');
  }

  async startPreview(): Promise<{ started: boolean }> {
    throw this.unavailable('Camera preview is not available on web.');
  }

  async stopPreview(): Promise<{ stopped: boolean }> {
    throw this.unavailable('Camera preview is not available on web.');
  }

  async capture(): Promise<ScanResult> {
    throw this.unavailable('Capture is not available on web.');
  }

  async setTorch(): Promise<{ enabled: boolean }> {
    throw this.unavailable('Torch is not available on web.');
  }
}
