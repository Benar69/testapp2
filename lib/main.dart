import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

void main() {
  runApp(const FlutterBlueApp());
}

class FlutterBlueApp extends StatefulWidget {
  const FlutterBlueApp({super.key});

  @override
  State<FlutterBlueApp> createState() => _FlutterBlueAppState();
}

class _FlutterBlueAppState extends State<FlutterBlueApp> {
  BluetoothAdapterState _adapterState = BluetoothAdapterState.unknown;
  late StreamSubscription<BluetoothAdapterState> _adapterStateSubscription;

  @override
  void initState() {
    super.initState();
    _adapterStateSubscription = FlutterBluePlus.adapterState.listen((state) {
      setState(() {
        _adapterState = state;
      });
    });
  }

  @override
  void dispose() {
    _adapterStateSubscription.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget screen;

    if (_adapterState == BluetoothAdapterState.on) {
      screen = const ScanScreen();
    } else {
      screen = BluetoothOffScreen(adapterState: _adapterState);
    }

    return MaterialApp(
      title: 'Tennis Machine Controller',
      home: screen,
    );
  }
}

class BluetoothOffScreen extends StatelessWidget {
  final BluetoothAdapterState adapterState;

  const BluetoothOffScreen({super.key, required this.adapterState});

  bool get isEmulator {
    if (kIsWeb) return false; // Web doesn't support Bluetooth
    return !Platform.isAndroid && !Platform.isIOS; // Assume it's an emulator if not Android/iOS
  }

  @override
  Widget build(BuildContext context) {
    bool bluetoothEnabled = isEmulator || adapterState == BluetoothAdapterState.on;

    if (bluetoothEnabled) {
      return const Scaffold(
        body: Center(child: Text('Bluetooth is enabled (Emulator bypass active).')),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Bluetooth Off')),
      body: Center(
        child: Text('Bluetooth is ${adapterState == BluetoothAdapterState.off ? "off" : "unknown"}. Please enable it.'),
      ),
    );
  }

  Future<bool> isRunningOnEmulator() async {
    final result = await Process.run('getprop', ['ro.boot.qemu']);
    return result.stdout.toString().trim() == '1';
  }
}

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  _ScanScreenState createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final FlutterBluePlus flutterBlue = FlutterBluePlus();
  List<BluetoothDevice> devicesList = [];
  BluetoothDevice? connectedDevice;
  BluetoothCharacteristic? commandCharacteristic;
  BluetoothCharacteristic? dataCharacteristic;
  bool isScanning = false;
  bool isConnected = false;

  // Pitching settings with default values
  int launcherSpeed = 1; // Default: 1
  int launcherSpin = 0; // Default: 0
  int ballInterval = 3; // Default: 3
  int verticalAngle = 3; // Default: 2
  int horizontalAngle = 3; // Default: 2
  bool enableLauncher = false; // Default: false
  bool enableVerticalSwing = false;
  bool enableHorizontalSwing = false;
  bool enableSequences = false;
  final TextEditingController _csvController = TextEditingController();

  // // Timer to handle subscription timeout
  // Timer? _dataTimeoutTimer;
  // Timer to handle connection check
  Timer? _connectionCheckTimer;

  @override
  void dispose() {
    // _dataTimeoutTimer?.cancel();
    _connectionCheckTimer?.cancel();
    super.dispose();
  }

  void startScan() async {
    setState(() {
      isScanning = true;
      devicesList.clear();
    });

    FlutterBluePlus.startScan(
      timeout: const Duration(seconds: 4),
      withServices: [Guid("895ae96b-ebc6-4e31-9193-40a9ae4dd3d8")],
    );

    FlutterBluePlus.scanResults.listen((results) {
      for (ScanResult r in results) {
        if (!devicesList.contains(r.device)) {
          setState(() {
            devicesList.add(r.device);
          });
        }
      }
    });

    await Future.delayed(const Duration(seconds: 4));
    await FlutterBluePlus.stopScan();

    setState(() {
      isScanning = false;
    });
  }

  void connectToDevice(BluetoothDevice device) async {
    await device.connect();
    List<BluetoothService> services = await device.discoverServices();

    BluetoothService? targetService;
    for (BluetoothService service in services) {
      for (BluetoothCharacteristic characteristic in service.characteristics) {
        if (characteristic.uuid.toString() == "895ae96b-ebc6-4e31-9193-40a9ae4dd3d9") {
          commandCharacteristic = characteristic;
        }
        else if (characteristic.uuid.toString() == "895ae96b-ebc6-4e31-9193-40a9ae4dd3a0")
        {
          dataCharacteristic = characteristic;
        }

        if (commandCharacteristic != null && dataCharacteristic != null) {
          targetService = service;
          break;
        }
      }
      if (targetService != null) break;
    }

    if (targetService != null && dataCharacteristic != null) {
      await dataCharacteristic!.setNotifyValue(true);
      
      try {
        // Read initial characteristic value
        var initialValue = await dataCharacteristic!.read();

        if (initialValue.isNotEmpty && initialValue.length >= 6) {
          updateValuesFromData(Uint8List.fromList(initialValue));
        } else {
          // If initial read fails, retain default values
          // Optionally, you can show a message or log this event
          if (kDebugMode) {
            print("Initial read returned empty or insufficient data. Using default values.");
          }
        }
      } catch (e) {
        // Handle read error and retain default values
        if (kDebugMode) {
          print("Error reading initial characteristic value: $e");
        }
      }

      // Subscribe to notifications
      dataCharacteristic!.lastValueStream.listen((value) {
        if (value.isNotEmpty && value.length >= 6) {
          updateValuesFromData(Uint8List.fromList(value));
        } else {
          if (kDebugMode) {
            print("Received empty or insufficient data.");
          }
        }
      }).onError((error) {
        // Handle stream errors
        if (kDebugMode) {
          print("Error in characteristic stream: $error");
        }
      });

      // Subscribe to device state changes
      device.connectionState.listen((BluetoothConnectionState state) {
        if (state == BluetoothConnectionState.disconnected) {
          disconnectDevice();
          if (kDebugMode) {
            print("Device disconnected");
          }
        }
      });

      setState(() {
        connectedDevice = device;
        isConnected = true;
      });
    } else {
      await device.disconnect();
      setState(() {
        connectedDevice = null;
        isConnected = false;
      });
      if (kDebugMode) {
        print("Target service or characteristic not found. Device disconnected.");
      }
    }
  }

  Future<bool> isDeviceConnected(BluetoothDevice device) async {
    bool isConnected = false;
    try {
      isConnected = device.connectionState == BluetoothConnectionState.connected;
    } catch (e) {
      if (kDebugMode) {
        print("Error checking device connection: $e");
      }
    }
    return isConnected;
  }

  void updateValuesFromData(Uint8List data) {
    // Ensure data has at least 6 bytes
    if (data.length < 6) {
      if (kDebugMode) {
        print("Data length is less than expected. Skipping update.");
      }
      return;
    }

    setState(() {
      launcherSpeed = data[0];
      launcherSpin = data[1] - 5;
      ballInterval = data[2];
      verticalAngle = data[3];
      horizontalAngle = data[4];
      enableLauncher = data[5] == 1;
      enableVerticalSwing = data[6] == 1;
      enableHorizontalSwing = data[7] == 1;
      enableSequences = data[8] == 1;
    });
  }

  void disconnectDevice() async {
    // _dataTimeoutTimer?.cancel(); // Cancel any existing timeout
    _connectionCheckTimer?.cancel();
    if (connectedDevice != null) {
      await connectedDevice!.disconnect();
      setState(() {
        connectedDevice = null;
        isConnected = false;
      });
      if (kDebugMode) {
        print("Device disconnected.");
      }
    }
  }

  void writeStringCommand(String command) async {
  if (commandCharacteristic != null) {
    Uint8List data = Uint8List.fromList(utf8.encode(command));
    await commandCharacteristic!.write(data);
    if (kDebugMode) {
      print("String command written: $command");
    }
  }
}

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Tennis Machine Controller')),
      body: SingleChildScrollView(
        child: Column(
          children: <Widget>[
            ElevatedButton(
              onPressed: isConnected ? disconnectDevice : startScan,
              child: Text(isConnected ? 'Disconnect' : 'Scan'),
            ),
            SizedBox(
              height: 120, // Adjust the height as needed
              child: ListView.builder(
                itemCount: devicesList.isEmpty ? 1 : devicesList.length,
                itemBuilder: (context, index) {
                  if (devicesList.isEmpty) {
                    return const ListTile(
                      title: Text('No devices found'),
                    );
                  }
                  return ListTile(
                    title: Text(devicesList[index].platformName.isNotEmpty
                        ? devicesList[index].platformName
                        : "Unknown Device"),
                    subtitle: Text(devicesList[index].remoteId.toString()),
                    onTap: () => connectToDevice(devicesList[index]),
                  );
                },
              ),
            ),
            Column(
              children: [
                SwitchListTile(
                  title: const Text('Start Machine'),
                  value: enableLauncher,
                  onChanged: isConnected
                      ? (value) {
                          setState(() {
                            enableLauncher = value;
                          });
                          writeStringCommand("start#$enableLauncher");
                        }
                      : null,
                ),
                Text("Speed: $launcherSpeed%"),
                Slider(
                  value: launcherSpeed.toDouble(),
                  min: 1,
                  max: 100,
                  divisions: 99,
                  label: launcherSpeed.toString(),
                  onChanged: isConnected
                      ? (value) {
                          setState(() {
                            launcherSpeed = value.toInt();
                          });
                        }
                      : null,
                  onChangeEnd: isConnected
                      ? (value) {
                          setState(() {
                            launcherSpeed = value.toInt();
                          });
                          writeStringCommand("speed#$launcherSpeed,$launcherSpin");
                        }
                      : null,
                ),
                Text("Spin: $launcherSpin"),
                Slider(
                  value: launcherSpin.toDouble(),
                  min: -5,
                  max: 5,
                  divisions: 10,
                  label: launcherSpin.toString(),
                  onChanged: isConnected
                      ? (value) {
                          setState(() {
                            launcherSpin = value.toInt();
                          });
                        }
                      : null,
                  onChangeEnd: isConnected
                      ? (value) {
                          setState(() {
                            launcherSpin = value.toInt();
                          });
                          writeStringCommand("speed#$launcherSpeed,$launcherSpin");
                        }
                      : null,
                ),
                Text("Ball Interval: $ballInterval Sec"),
                Slider(
                  value: ballInterval.toDouble(),
                  min: 1,
                  max: 10,
                  divisions: 9,
                  label: ballInterval.toString(),
                  onChanged: isConnected
                      ? (value) {
                          setState(() {
                            ballInterval = value.toInt();
                          });
                        }
                      : null,
                  onChangeEnd: isConnected
                      ? (value) {
                          setState(() {
                            ballInterval = value.toInt();
                          });
                          writeStringCommand("interval#$ballInterval");
                        }
                      : null,
                ),           
                SwitchListTile(
                  title: const Text('Oscillate Vertical'),
                  value: enableVerticalSwing,
                  onChanged: isConnected
                      ? (value) {
                          setState(() {
                            enableVerticalSwing = value;
                          });
                          writeStringCommand("vosc#$enableVerticalSwing");
                        }
                      : null,
                ),
                SwitchListTile(
                  title: const Text('Oscillate Horizontal'),
                  value: enableHorizontalSwing,
                  onChanged: isConnected
                      ? (value) {
                          setState(() {
                            enableHorizontalSwing = value;
                          });
                          writeStringCommand("hosc#$enableHorizontalSwing");
                        }
                      : null,
                ),
                Text("Elevation Pos: $verticalAngle"),
                Slider(
                  value: verticalAngle.toDouble(),
                  min: 0,
                  max: 5,
                  divisions: 5,
                  label: verticalAngle.toString(),
                  onChanged: isConnected
                      ? (value) {
                          setState(() {
                            verticalAngle = value.toInt();
                          });
                        }
                      : null,
                  onChangeEnd: isConnected
                      ? (value) {
                          setState(() {
                            verticalAngle = value.toInt();
                          });
                          writeStringCommand("vpos#$verticalAngle");
                        }
                      : null,
                ),
                Text("Horizontal Pos: $horizontalAngle"),
                Slider(
                  value: horizontalAngle.toDouble(),
                  min: 0,
                  max: 5,
                  divisions: 5,
                  label: horizontalAngle.toString(),
                  onChanged: isConnected
                      ? (value) {
                          setState(() {
                            horizontalAngle = value.toInt();
                          });
                        }
                      : null,
                  onChangeEnd: isConnected
                      ? (value) {
                          setState(() {
                            horizontalAngle = value.toInt();
                          });
                          writeStringCommand("hpos#$horizontalAngle");
                        }
                      : null,
                ),
                
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: TextField(
                    controller: _csvController,
                    decoration: const InputDecoration(
                      labelText: "Enter Sequences",
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                ElevatedButton(
                  onPressed: isConnected
                      ? () {
                          String csvCommand = _csvController.text.trim();
                          if (csvCommand.isNotEmpty) {
                            writeStringCommand(csvCommand);
                            _csvController.clear();
                          }
                        }
                      : null,
                  child: const Text("Send Command"),
                ),
                SwitchListTile(
                  title: const Text('Start Sequences'),
                  value: enableSequences,
                  onChanged: isConnected
                      ? (value) {
                          setState(() {
                            enableSequences = value;
                          });
                          writeStringCommand("seq#$enableSequences");
                        }
                      : null,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

}
