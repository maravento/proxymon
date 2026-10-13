<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Logview — Proxy Monitor</title>
<style>
*{box-sizing:border-box}body{margin:0;height:100vh;display:flex;flex-direction:column;font-family:system-ui,sans-serif;background:#f0f4f8;color:#263238;color-scheme:light}html.dark body{background:#1e2a35;color:white;color-scheme:dark}
nav{display:flex;gap:8px;padding:10px;align-items:center;background:#1e2a35;color:#fff;color-scheme:dark}nav strong{margin-right:12px}.tabs{display:flex;gap:8px}#btnTheme{margin-left:auto}button{padding:9px 16px;border:1px solid #607d8b;border-radius:5px;background:transparent;color:inherit;cursor:pointer}button[aria-selected="true"]{background:#1565c0;border-color:#1565c0;color:white}button:focus-visible{outline:2px solid currentColor;outline-offset:2px}
iframe{border:0;width:100%;flex:1;min-height:0;background:white}html.dark body iframe{background:#0f1117}iframe[hidden]{display:none}
</style>
<script src="theme.js"></script>
</head>
<body>
<nav aria-label="Logview">
<strong>Logview</strong>
<div class="tabs" role="tablist" aria-label="Logview views">
<button id="accessTab" role="tab" aria-controls="accessFrame" aria-selected="true" onclick="selectView('access')">Log</button>
<button id="connectionsTab" role="tab" aria-controls="connectionsFrame" aria-selected="false" tabindex="-1" onclick="selectView('connections')">Live</button>
</div>
<button id="btnTheme" type="button" onclick="logviewTheme.toggle()" aria-label="Switch to light theme" aria-pressed="true" title="Switch to light theme">☀️</button>
</nav>
<iframe id="accessFrame" role="tabpanel" aria-labelledby="accessTab" title="Log" src="access.php"></iframe>
<iframe id="connectionsFrame" role="tabpanel" aria-labelledby="connectionsTab" title="Live" hidden></iframe>
<script>
var currentView = 'access';
function notifyView(name) {
  var frame = document.getElementById(name + 'Frame');
  frame.contentWindow.postMessage({type:'logview-visibility',visible:name === currentView}, location.origin);
}
function selectView(name) {
  currentView = name;
  ['access','connections'].forEach(function(view) {
    var selected = view === name;
    var tab = document.getElementById(view + 'Tab');
    var frame = document.getElementById(view + 'Frame');
    tab.setAttribute('aria-selected', String(selected));
    tab.tabIndex = selected ? 0 : -1;
    frame.hidden = !selected;
    if (selected && view === 'connections' && !frame.hasAttribute('src')) frame.src = 'connections.php';
    if (frame.hasAttribute('src')) notifyView(view);
  });
}
['access','connections'].forEach(function(view) {
  document.getElementById(view + 'Frame').addEventListener('load',function(){notifyView(view);logviewTheme.sync(document.getElementById(view + 'Frame'));});
  document.getElementById(view + 'Tab').addEventListener('keydown',function(event){
    if (!['ArrowLeft','ArrowRight','Home','End'].includes(event.key)) return;
    event.preventDefault();
    var next = event.key === 'Home' ? 'access' : event.key === 'End' ? 'connections' : view === 'access' ? 'connections' : 'access';
    selectView(next); document.getElementById(next + 'Tab').focus();
  });
});
</script>
</body>
</html>
