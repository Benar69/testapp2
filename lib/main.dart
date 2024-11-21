import 'dart:async';
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Bluetooth Off')),
      body: Center(
        child: Text('Bluetooth is ${adapterState == BluetoothAdapterState.off ? "off" : "unknown"}. Please enable it.'),
      ),
    );
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
  BluetoothCharacteristic? targetCharacteristic;
  bool isScanning = false;
  bool isConnected = false;

  // Pitching settings with default values
  int launcherSpeed = 1; // Default: 1
  int launcherSpin = 0; // Default: 0
  int feedDelay = 3; // Default: 3
  int verticalAngle = 0; // Default: 15
  int presetMode = 0;
  bool enableLauncher = false; // Default: false

  // Timer to handle subscription timeout
  Timer? _dataTimeoutTimer;
  // Timer to handle connection check
  Timer? _connectionCheckTimer;

  @override
  void dispose() {
    _dataTimeoutTimer?.cancel();
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
        if (characteristic.uuid.toString() == "895ae96b-ebc6-4e31-9193-40a9ae4dd3d8") {
          targetService = service;
          targetCharacteristic = characteristic;
          break;
        }
      }
      if (targetService != null) break;
    }

    if (targetService != null && targetCharacteristic != null) {
      await targetCharacteristic!.setNotifyValue(true);
      
      try {
        // Read initial characteristic value
        var initialValue = await targetCharacteristic!.read();

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

      // Set up a timeout to use default values if no data is received within 5 seconds
      _dataTimeoutTimer = Timer(const Duration(seconds: 5), () {
        setState(() {
          // Revert to default values
          launcherSpeed = 1;
          launcherSpin = 0;
          feedDelay = 3;
          verticalAngle = 0;
          enableLauncher = false;
          presetMode = 0;
        });
        if (kDebugMode) {
          print("No data received within timeout. Using default values.");
        }
      });

      // Subscribe to notifications
      targetCharacteristic!.lastValueStream.listen((value) {
        if (value.isNotEmpty && value.length >= 6) {
          _dataTimeoutTimer?.cancel(); // Data received, cancel the timeout
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
      launcherSpin = data[1] - 10;
      feedDelay = data[2];
      verticalAngle = data[3];
      enableLauncher = data[4] == 1;
      presetMode = data[5];
    });
  }

  void disconnectDevice() async {
    _dataTimeoutTimer?.cancel(); // Cancel any existing timeout
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

  void writeCommandData() async {
    if (targetCharacteristic != null) {
      Uint8List data = Uint8List(6);
      data[0] = launcherSpeed;
      data[1] = launcherSpin + 10;
      data[2] = feedDelay;
      data[3] = verticalAngle;
      data[4] = enableLauncher ? 1 : 0;
      data[5] = presetMode;
      await targetCharacteristic!.write(data);
      if (kDebugMode) {
        print("Command data written: $data");
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Tennis Machine Controller')),
      body: Column(
        children: <Widget>[
          ElevatedButton(
            onPressed: isConnected ? disconnectDevice : startScan,
            child: Text(isConnected ? 'Disconnect' : 'Scan'),
          ),
          Expanded(
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
                        writeCommandData();
                      }
                    : null,
              ),
              Text("Elevation Pos: $verticalAngle"),
              Slider(
                value: verticalAngle.toDouble(),
                min: 0,
                max: 15,
                divisions: 15,
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
                        writeCommandData();
                      }
                    : null,
              ),
              Text("Frequency: $feedDelay Sec"),
              Slider(
                value: feedDelay.toDouble(),
                min: 1,
                max: 10,
                divisions: 10,
                label: feedDelay.toString(),
                onChanged: isConnected
                    ? (value) {
                        setState(() {
                          feedDelay = value.toInt();
                        });
                      }
                    : null,
                onChangeEnd: isConnected
                    ? (value) {
                        setState(() {
                          feedDelay = value.toInt();
                        });
                        writeCommandData();
                      }
                    : null,
              ),
              Text("Speed: $launcherSpeed%"),
              Slider(
                value: launcherSpeed.toDouble(),
                min: 1,
                max: 100,
                divisions: 100,
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
                        writeCommandData();
                      }
                    : null,
              ),
              Text("Spin: $launcherSpin"),
              Slider(
                value: launcherSpin.toDouble(),
                min: -10,
                max: 10,
                divisions: 20,
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
                        writeCommandData();
                      }
                    : null,
              ),              
            ],
          ),
        ],
      ),
    );
  }

}
