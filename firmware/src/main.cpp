// ESP32-S3 firmware for the iPhone rig.
//
// The board pairs with the iPhone as a Bluetooth LE mouse + keyboard
// ("Claude Rig"). The Mac sends one command per line over USB serial
// (115200 baud) and gets one reply line: "OK ..." or "ERR ...".
//
//   PING                      -> OK PONG
//   STATUS                    -> OK connected=1 x=.. y=.. step=.. delay=..
//   CFG <step> <delay_ms>     pointer step size per report and pause between reports
//   CORNER                    push the pointer into the top-left corner, position = 0,0
//   MOVE <dx> <dy>            relative move in mouse counts
//   MOVETO <x> <y>            move to x,y counts from the corner (tracked, may drift)
//   CLICK [hold_ms]           left click
//   DOWN / UP                 hold / release the left button (for drags and swipes)
//   TAP <x> <y> [hold_ms]     MOVETO then CLICK
//   SCROLL <n>                wheel, positive = up
//   TYPE <text>               type ASCII text (US layout)
//   KEY <combo>               e.g. enter, backspace, esc, tab, up, cmd+space, shift+tab, a
//   CONSUMER <usage>          consumer-control usage, hex or decimal (e.g. 0x223)

#include <Arduino.h>
#include <NimBLEDevice.h>
#include <NimBLEHIDDevice.h>

static const char *DEVICE_NAME = "Claude Rig";

// Report 1: keyboard, report 2: mouse (3 buttons, x, y, wheel), report 3: consumer control.
static const uint8_t REPORT_MAP[] = {
    0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x85, 0x01,             // Keyboard, report 1
    0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00, 0x25, 0x01, //  modifiers
    0x75, 0x01, 0x95, 0x08, 0x81, 0x02,
    0x95, 0x01, 0x75, 0x08, 0x81, 0x01,                         //  reserved byte
    0x95, 0x05, 0x75, 0x01, 0x05, 0x08, 0x19, 0x01, 0x29, 0x05, //  LEDs (output)
    0x91, 0x02, 0x95, 0x01, 0x75, 0x03, 0x91, 0x01,
    0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x25, 0x65,             //  6 key slots
    0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00,
    0xC0,
    0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x85, 0x02,             // Mouse, report 2
    0x09, 0x01, 0xA1, 0x00,
    0x05, 0x09, 0x19, 0x01, 0x29, 0x03, 0x15, 0x00, 0x25, 0x01, //  3 buttons
    0x95, 0x03, 0x75, 0x01, 0x81, 0x02,
    0x95, 0x01, 0x75, 0x05, 0x81, 0x03,                         //  padding
    0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x09, 0x38,             //  x, y, wheel
    0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x03, 0x81, 0x06,
    0xC0, 0xC0,
    0x05, 0x0C, 0x09, 0x01, 0xA1, 0x01, 0x85, 0x03,             // Consumer, report 3
    0x15, 0x00, 0x26, 0xFF, 0x03, 0x19, 0x00, 0x2A, 0xFF, 0x03,
    0x75, 0x10, 0x95, 0x01, 0x81, 0x00,
    0xC0,
};

static NimBLEServer *server = nullptr;
static NimBLEHIDDevice *hid = nullptr;
static NimBLECharacteristic *kbIn = nullptr, *mouseIn = nullptr, *consumerIn = nullptr;

static int stepSize = 8;   // counts per mouse report
static int stepDelay = 6;  // ms between reports
static long curX = 0, curY = 0;
static uint8_t buttons = 0;

class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer *s, ble_gap_conn_desc *desc) override {
    Serial.println("EVENT connected");
  }
  void onDisconnect(NimBLEServer *s) override {
    Serial.println("EVENT disconnected");
    NimBLEDevice::startAdvertising();
  }
};

static bool connected() { return server && server->getConnectedCount() > 0; }

// ---------- mouse ----------

static void sendMouse(int dx, int dy, int wheel) {
  uint8_t r[4] = {buttons, (uint8_t)(int8_t)dx, (uint8_t)(int8_t)dy, (uint8_t)(int8_t)wheel};
  mouseIn->setValue(r, sizeof(r));
  mouseIn->notify();
}

static void moveRel(long dx, long dy, int step, int pause) {
  while (dx != 0 || dy != 0) {
    int sx = (int)constrain(dx, (long)-step, (long)step);
    int sy = (int)constrain(dy, (long)-step, (long)step);
    sendMouse(sx, sy, 0);
    dx -= sx; dy -= sy; curX += sx; curY += sy;
    delay(pause);
  }
}

static void corner() {
  moveRel(-4000, -4000, 100, 4);
  curX = 0; curY = 0;
  delay(60);
}

static void setButton(bool down) {
  buttons = down ? 0x01 : 0x00;
  sendMouse(0, 0, 0);
}

static void click(int holdMs) {
  setButton(true);
  delay(holdMs);
  setButton(false);
}

// ---------- keyboard ----------

static void sendKeys(uint8_t mods, uint8_t key) {
  uint8_t r[8] = {mods, 0, key, 0, 0, 0, 0, 0};
  kbIn->setValue(r, sizeof(r));
  kbIn->notify();
}

static void pressKey(uint8_t mods, uint8_t key) {
  sendKeys(mods, key);
  delay(18);
  sendKeys(0, 0);
  delay(18);
}

// US layout: ASCII -> HID usage, with shift flag.
static bool asciiToKey(char c, uint8_t &key, bool &shift) {
  shift = false;
  if (c >= 'a' && c <= 'z') { key = 0x04 + (c - 'a'); return true; }
  if (c >= 'A' && c <= 'Z') { key = 0x04 + (c - 'A'); shift = true; return true; }
  if (c >= '1' && c <= '9') { key = 0x1E + (c - '1'); return true; }
  if (c == '0') { key = 0x27; return true; }
  const char *plain = " -=[]\\;'`,./";
  const uint8_t plainKeys[] = {0x2C, 0x2D, 0x2E, 0x2F, 0x30, 0x31, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38};
  const char *shifted = "_+{}|:\"~<>?";
  const uint8_t shiftedKeys[] = {0x2D, 0x2E, 0x2F, 0x30, 0x31, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38};
  const char *top = "!@#$%^&*()";
  for (int i = 0; plain[i]; i++) if (c == plain[i]) { key = plainKeys[i]; return true; }
  for (int i = 0; shifted[i]; i++) if (c == shifted[i]) { key = shiftedKeys[i]; shift = true; return true; }
  for (int i = 0; top[i]; i++) if (c == top[i]) { key = (i == 9) ? 0x27 : 0x1E + i; shift = true; return true; }
  if (c == '\n') { key = 0x28; return true; }
  if (c == '\t') { key = 0x2B; return true; }
  return false;
}

static int typeText(const String &text) {
  int skipped = 0;
  for (size_t i = 0; i < text.length(); i++) {
    uint8_t key; bool shift;
    if (!asciiToKey(text[i], key, shift)) { skipped++; continue; }
    pressKey(shift ? 0x02 : 0x00, key);
  }
  return skipped;
}

static bool namedKey(const String &n, uint8_t &key) {
  struct { const char *name; uint8_t key; } table[] = {
      {"enter", 0x28}, {"return", 0x28}, {"esc", 0x29}, {"escape", 0x29}, {"backspace", 0x2A},
      {"tab", 0x2B}, {"space", 0x2C}, {"delete", 0x4C}, {"home", 0x4A}, {"end", 0x4D},
      {"pageup", 0x4B}, {"pagedown", 0x4E}, {"right", 0x4F}, {"left", 0x50}, {"down", 0x51},
      {"up", 0x52}};
  for (auto &e : table) if (n == e.name) { key = e.key; return true; }
  if (n.length() == 1) { bool s; return asciiToKey(n[0], key, s); }
  return false;
}

// "cmd+shift+a" -> modifiers + key
static bool parseCombo(String combo, uint8_t &mods, uint8_t &key) {
  combo.toLowerCase();
  mods = 0; key = 0;
  int start = 0;
  while (true) {
    int plus = combo.indexOf('+', start);
    String part = combo.substring(start, plus < 0 ? combo.length() : plus);
    part.trim();
    if (part == "ctrl" || part == "control") mods |= 0x01;
    else if (part == "shift") mods |= 0x02;
    else if (part == "alt" || part == "option" || part == "opt") mods |= 0x04;
    else if (part == "cmd" || part == "command" || part == "gui" || part == "win") mods |= 0x08;
    else if (!namedKey(part, key)) return false;
    if (plus < 0) break;
    start = plus + 1;
  }
  return key != 0 || mods != 0;
}

static void consumer(uint16_t usage) {
  uint8_t r[2] = {(uint8_t)(usage & 0xFF), (uint8_t)(usage >> 8)};
  consumerIn->setValue(r, 2);
  consumerIn->notify();
  delay(30);
  uint8_t z[2] = {0, 0};
  consumerIn->setValue(z, 2);
  consumerIn->notify();
}

// ---------- commands ----------

static String nextToken(String &rest) {
  rest.trim();
  int sp = rest.indexOf(' ');
  String tok = sp < 0 ? rest : rest.substring(0, sp);
  rest = sp < 0 ? "" : rest.substring(sp + 1);
  return tok;
}

static void handle(String line) {
  line.trim();
  if (line.length() == 0) return;
  String rest = line;
  String cmd = nextToken(rest);
  cmd.toUpperCase();

  if (cmd == "PING") { Serial.println("OK PONG"); return; }
  if (cmd == "STATUS") {
    Serial.printf("OK connected=%d x=%ld y=%ld step=%d delay=%d\n", connected() ? 1 : 0, curX, curY, stepSize, stepDelay);
    return;
  }
  if (cmd == "CFG") {
    int s = nextToken(rest).toInt(), d = nextToken(rest).toInt();
    if (s < 1 || s > 127 || d < 0 || d > 100) { Serial.println("ERR usage: CFG <step 1-127> <delay_ms 0-100>"); return; }
    stepSize = s; stepDelay = d;
    Serial.printf("OK step=%d delay=%d\n", stepSize, stepDelay);
    return;
  }
  if (!connected()) { Serial.println("ERR not connected to the iPhone"); return; }

  if (cmd == "CORNER") { corner(); Serial.println("OK x=0 y=0"); }
  else if (cmd == "MOVE") {
    long dx = nextToken(rest).toInt(), dy = nextToken(rest).toInt();
    moveRel(dx, dy, stepSize, stepDelay);
    Serial.printf("OK x=%ld y=%ld\n", curX, curY);
  }
  else if (cmd == "MOVETO" || cmd == "TAP") {
    long x = nextToken(rest).toInt(), y = nextToken(rest).toInt();
    moveRel(x - curX, y - curY, stepSize, stepDelay);
    if (cmd == "TAP") {
      String h = nextToken(rest);
      delay(40);
      click(h.length() ? h.toInt() : 50);
    }
    Serial.printf("OK x=%ld y=%ld\n", curX, curY);
  }
  else if (cmd == "CLICK") { String h = nextToken(rest); click(h.length() ? h.toInt() : 50); Serial.println("OK"); }
  else if (cmd == "DOWN") { setButton(true); Serial.println("OK"); }
  else if (cmd == "UP") { setButton(false); Serial.println("OK"); }
  else if (cmd == "SCROLL") {
    long n = nextToken(rest).toInt();
    while (n != 0) { int s = (int)constrain(n, -10L, 10L); sendMouse(0, 0, s); n -= s; delay(stepDelay + 10); }
    Serial.println("OK");
  }
  else if (cmd == "TYPE") {
    int skipped = typeText(rest);
    if (skipped) Serial.printf("OK skipped=%d non-ASCII characters\n", skipped); else Serial.println("OK");
  }
  else if (cmd == "KEY") {
    uint8_t mods, key;
    if (!parseCombo(rest, mods, key)) { Serial.println("ERR unknown key combo"); return; }
    pressKey(mods, key);
    Serial.println("OK");
  }
  else if (cmd == "CONSUMER") {
    rest.trim();
    long usage = strtol(rest.c_str(), nullptr, 0);
    if (usage <= 0 || usage > 0x3FF) { Serial.println("ERR usage must be 1..0x3FF"); return; }
    consumer((uint16_t)usage);
    Serial.println("OK");
  }
  else Serial.println("ERR unknown command");
}

void setup() {
  Serial.begin(115200);
  NimBLEDevice::init(DEVICE_NAME);
  NimBLEDevice::setSecurityAuth(true, true, true);  // bond, "just works" pairing
  NimBLEDevice::setSecurityIOCap(BLE_HS_IO_NO_INPUT_OUTPUT);

  server = NimBLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());

  hid = new NimBLEHIDDevice(server);
  kbIn = hid->inputReport(1);
  hid->outputReport(1);  // keyboard LEDs; required by some hosts
  mouseIn = hid->inputReport(2);
  consumerIn = hid->inputReport(3);

  hid->manufacturer()->setValue("DIY");
  hid->pnp(0x02, 0xE502, 0xA111, 0x0210);
  hid->hidInfo(0x00, 0x02);
  hid->reportMap((uint8_t *)REPORT_MAP, sizeof(REPORT_MAP));
  hid->startServices();
  hid->setBatteryLevel(100);

  NimBLEAdvertising *adv = NimBLEDevice::getAdvertising();
  adv->setAppearance(0x03C0);  // generic HID
  adv->addServiceUUID(hid->hidService()->getUUID());
  adv->setScanResponse(true);
  adv->start();
  Serial.println("EVENT ready, advertising as Claude Rig");
}

void loop() {
  static String buf;
  while (Serial.available()) {
    char c = (char)Serial.read();
    if (c == '\n' || c == '\r') { if (buf.length()) { handle(buf); buf = ""; } }
    else if (buf.length() < 512) buf += c;
  }
  delay(2);
}
