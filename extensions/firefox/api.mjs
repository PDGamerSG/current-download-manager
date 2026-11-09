/* Chrome callbacks must consume runtime.lastError inside their callback. */
export const api = globalThis.browser || globalThis.chrome;
export const isFirefox = typeof globalThis.browser !== 'undefined';
export function callAPI(owner, method, ...args) {
  if (!owner || typeof owner[method] !== 'function') return Promise.reject(new Error(`Browser API unavailable: ${method}`));
  if (isFirefox) {
    try { return Promise.resolve(owner[method](...args)); } catch (error) { return Promise.reject(error); }
  }
  return new Promise((resolve, reject) => {
    try {
      owner[method](...args, result => {
        const failure = api.runtime.lastError;
        if (failure) reject(new Error(failure.message || String(failure)));
        else resolve(result);
      });
    } catch (error) { reject(error); }
  });
}
export function nativeMessage(message, timeout = 20000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('Current did not respond within 20 seconds. Open Current and check the browser host installation.')), timeout);
    callAPI(api.runtime, 'sendNativeMessage', 'io.current.downloadmanager', message).then(value => {
      clearTimeout(timer);
      if (!value || typeof value.ok !== 'boolean') reject(new Error('Current returned an invalid native message.'));
      else if (!value.ok) reject(new Error(value.error || 'Current could not complete the request.'));
      else resolve(value);
    }, error => {
      clearTimeout(timer);
      reject(new Error(`Cannot reach Current: ${error.message}. Open Current and install its browser host.`));
    });
  });
}
