ObjC.import('Foundation');

function readInput(path) {
  return JSON.parse(
    ObjC.unwrap(
      $.NSString.stringWithContentsOfFileEncodingError(
        path,
        $.NSUTF8StringEncoding,
        null
      )
    )
  );
}

function finderPath(item) {
  const raw = String(item.url());
  const url = $.NSURL.URLWithString(raw);
  if (!url) throw new Error('invalid_finder_url:' + raw);
  return ObjC.unwrap(url.path);
}

function dispatch(operation, input) {
  const systemEvents = Application('System Events');
  switch (operation) {
    case 'system.volume.get': {
      const app = Application.currentApplication();
      app.includeStandardAdditions = true;
      const volume = app.getVolumeSettings();
      return {
        output_volume: Number(volume.outputVolume),
        output_muted: Boolean(volume.outputMuted),
      };
    }
    case 'system.volume.set': {
      const app = Application.currentApplication();
      app.includeStandardAdditions = true;
      app.setVolume(null, { outputVolume: input.value });
      return { value: input.value };
    }
    case 'system.volume.mute': {
      const app = Application.currentApplication();
      app.includeStandardAdditions = true;
      app.setVolume(null, { outputMuted: input.muted });
      return { muted: input.muted };
    }
    case 'system.appearance.get':
      return {
        appearance: systemEvents.appearancePreferences.darkMode() ? 'dark' : 'light',
      };
    case 'system.appearance.set':
      systemEvents.appearancePreferences.darkMode = input.appearance === 'dark';
      return { appearance: input.appearance };
    case 'system.wallpaper.get':
      return {
        desktops: systemEvents.desktops().map((desktop, display) => ({
          display,
          path: String(desktop.picture()),
        })),
      };
    case 'system.wallpaper.set': {
      const path = ObjC.unwrap($(input.path).stringByStandardizingPath);
      const desktops = systemEvents.desktops();
      if (input.display === undefined) {
        desktops.forEach((desktop) => { desktop.picture = path; });
      } else {
        if (input.display < 0 || input.display >= desktops.length) {
          throw new Error('display_not_found');
        }
        desktops[input.display].picture = path;
      }
      return {
        path,
        display: input.display === undefined ? null : input.display,
      };
    }
    case 'system.sleep':
      systemEvents.sleep();
      return { requested: true };
    case 'system.restart':
      systemEvents.restart();
      return { requested: true };
    case 'system.shutdown':
      systemEvents.shutDown();
      return { requested: true };
    case 'finder.selection.list': {
      const finder = Application('Finder');
      return { paths: finder.selection().map(finderPath) };
    }
    default:
      throw new Error('unsupported_operation:' + operation);
  }
}

function run(argv) {
  try {
    return JSON.stringify({ ok: true, data: dispatch(argv[0], readInput(argv[1])) });
  } catch (error) {
    return JSON.stringify({
      ok: false,
      error: {
        code: 'system_operation_failed',
        message: String(error.message || error),
      },
    });
  }
}
