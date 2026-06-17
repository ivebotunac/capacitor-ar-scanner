import { registerPlugin } from '@capacitor/core';

import type { ARScannerPlugin } from './definitions';

const ARScanner = registerPlugin<ARScannerPlugin>('ARScanner', {
  web: () => import('./web').then((m) => new m.ARScannerWeb()),
});

export * from './definitions';
export { ARScanner };
