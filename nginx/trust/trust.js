// The trust page (backend plan 24 section 11, OP5): name this server, point "Open HMS" at HTTPS, and open
// the steps for this device.
(function () {
  var host = location.hostname;
  var names = document.querySelectorAll('.host');
  for (var i = 0; i < names.length; i++) names[i].textContent = host;
  document.getElementById('open-hms').href = 'https://' + host + '/';

  var ua = navigator.userAgent;
  var os = 'windows';
  if (/iPhone|iPad|iPod/.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1)) os = 'ios';
  else if (/Android/.test(ua)) os = 'android';
  else if (/Macintosh/.test(ua)) os = 'mac';
  var section = document.querySelector('details[data-os="' + os + '"]');
  if (section) section.open = true;
})();
