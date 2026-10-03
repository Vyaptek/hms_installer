// Plain HTTP on a box with HTTPS (backend plan 24 section 11, OP5): does this device already trust the
// box? A fetch of https://<same host>/trust/ok.txt fails when the certificate is not trusted (or when the
// network drops it), and an opaque answer is enough to know it is. Trusted: the same page over HTTPS.
// Otherwise: the trust page, which says how to set this device up.
(function () {
  var done = false;
  function go(url) {
    if (done) return;
    done = true;
    location.replace(url);
  }
  var https = 'https://' + location.hostname;
  var timer = setTimeout(function () { go('/trust/'); }, 5000);
  if (!window.fetch) {
    go('/trust/');
    return;
  }
  fetch(https + '/trust/ok.txt', { mode: 'no-cors', cache: 'no-store' })
    .then(function () {
      clearTimeout(timer);
      go(https + location.pathname + location.search + location.hash);
    })
    .catch(function () {
      clearTimeout(timer);
      go('/trust/');
    });
})();
