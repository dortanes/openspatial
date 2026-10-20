// Netflix asks only for stereo AAC in Safari. Its player builds the playback request with JSON.stringify,
// so the page's own JSON.stringify adds the Dolby Digital Plus profiles to that request; Netflix picks the best one.
function requestSurround() {
  const surround = ['ddplus-2.0-dash', 'ddplus-5.1-dash', 'ddplus-5.1hq-dash', 'ddplus-atmos-dash'];
  const stringify = JSON.stringify;
  const addSurround = (node, depth) => {
    if (!node || typeof node !== 'object' || depth > 4) return;
    if (Array.isArray(node.profiles) && node.profiles.some((profile) => typeof profile === 'string' && profile.includes('aac'))) {
      for (const profile of surround) if (!node.profiles.includes(profile)) node.profiles.push(profile);
    }
    for (const key in node) addSurround(node[key], depth + 1);
  };
  JSON.stringify = function (value, ...rest) {
    try {
      addSurround(value, 0);
    } catch {}
    return stringify.call(this, value, ...rest);
  };
}

// A content script has its own JSON object, so the change runs in the page through an inline script.
const script = document.createElement('script');
script.textContent = `(${requestSurround})();`;
document.documentElement.append(script);
script.remove();
