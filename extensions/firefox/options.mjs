import {api, callAPI} from './api.mjs';
import {validateCapturePolicy} from './core.mjs';

const $ = id => document.getElementById(id);
const lines = value => value.split(/\r?\n/).map(rule => rule.trim()).filter(Boolean);
async function send(message) {
  const response = await callAPI(api.runtime, 'sendMessage', message);
  if (!response?.ok) throw new Error(response?.error || 'Current could not save the capture settings.');
  return response;
}
function showError(error) {
  $('settings-error').textContent = error.message || String(error);
  $('settings-error').hidden = false;
}
function render(settings) {
  $('file-types').value = settings.policy.fileTypes.join(', ');
  $('excluded-domains').value = settings.policy.excludedDomains.join('\n');
  $('excluded-url-patterns').value = settings.policy.excludedURLPatterns.join('\n');
  $('capture-state').textContent = `Automatic capture is ${settings.captureEnabled ? 'enabled' : 'disabled'}. Change it in the Current toolbar popup.`;
}
$('settings-form').addEventListener('submit', async event => {
  event.preventDefault();
  $('save-settings').disabled = true;
  $('settings-feedback').textContent = '';
  $('settings-error').hidden = true;
  try {
    const policy = validateCapturePolicy({
      fileTypes:$('file-types').value.split(/[\s,;]+/).filter(Boolean),
      excludedDomains:lines($('excluded-domains').value),
      excludedURLPatterns:lines($('excluded-url-patterns').value)
    });
    render(await send({action:'set-capture-policy', policy}));
    $('settings-feedback').textContent = 'Capture rules saved.';
  } catch (error) { showError(error); }
  finally { $('save-settings').disabled = false; }
});
try { render(await send({action:'get-capture-policy'})); }
catch (error) {
  $('capture-state').textContent = 'Capture rules could not be loaded. Save valid rules to restore automatic capture.';
  showError(error);
}
finally { $('save-settings').disabled = false; }
