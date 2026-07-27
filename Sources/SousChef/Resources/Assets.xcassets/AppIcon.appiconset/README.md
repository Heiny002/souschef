# App icon

Drop the icon here as **Icon-1024.png** (that exact filename — Contents.json
references it).

Requirements Apple enforces at submission, and Xcode warns about locally:

- **1024 x 1024 pixels**, square.
- **PNG**, no transparency / alpha channel. A transparent icon is rejected;
  the artwork must fill the whole square with its own background colour.
- **No rounded corners of your own** — iOS masks the corners itself. Supply a
  full square or the mask will clip your artwork twice.
- Keep important artwork away from the very edge: the corner mask eats roughly
  10% on each side.

This is the modern single-size app icon (Xcode 14+); iOS generates every
smaller size from the 1024 automatically, so only one file is needed.
