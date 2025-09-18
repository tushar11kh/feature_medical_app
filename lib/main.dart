import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:math' as math;
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'package:flutter/foundation.dart'; // for kIsWeb
import 'dart:convert'; // For utf8 encoding
import 'package:crypto/crypto.dart'; // For computing md5 hash
import 'dart:html' as html; // For web file saving
import 'dart:ui' as ui; // For converting widgets to images

void main() => runApp(MyApp());

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Image Gallery with Drawing',
      home: ImageGalleryScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class ImageGalleryScreen extends StatefulWidget {
  @override
  _ImageGalleryScreenState createState() => _ImageGalleryScreenState();
}

class _ImageGalleryScreenState extends State<ImageGalleryScreen> {
  List<XFile> selectedImages = [];
  List<Uint8List> selectedImageBytes = [];
  int selectedIndex = 0;
  FocusNode focusNode = FocusNode();
  Offset? _startPoint;
  Offset? _endPoint;
  String? _labelText;
  bool _isDrawing = false;
  bool _isLabeling = false;
  TextEditingController _labelController = TextEditingController();
  Map<String, List<Drawing>> _imageDrawings = {};
  List<Drawing> get _currentDrawings =>
      _imageDrawings[selectedImages.isNotEmpty
              ? selectedImages[selectedIndex].path
              : ''] ??=
          [];
  Drawing? _draggingLabel;
  Offset? _dragOffset;
  List<List<Drawing>> _undoStack = [];
  List<List<Drawing>> _redoStack = [];
  Set<String> imageHashes = {};

  Future<void> _pickImage() async {
    final picker = ImagePicker();

    // Show loading indicator (Chrome can handle large batches smoothly)
    // ScaffoldMessenger.of(context).showSnackBar(
    //   SnackBar(
    //     content: Row(
    //       children: [
    //         CircularProgressIndicator(),
    //         SizedBox(width: 20),
    //       ],
    //     ),
    //     duration: Duration(seconds: 2),
    //   ),
    // );

    try {
      final List<XFile> pickedFiles = await picker.pickMultiImage();
      if (pickedFiles.isEmpty) return;

      int successfullyAdded = 0;
      int duplicatesSkipped = 0;

      // Process all images in parallel (Chrome handles this well)
      await Future.wait(
        pickedFiles.map((pickedFile) async {
          try {
            final bytes = await pickedFile.readAsBytes();
            final hash = md5.convert(bytes).toString();

            if (!imageHashes.contains(hash)) {
              // Use `setState` only once after all images are processed
              imageHashes.add(hash);
              selectedImages.add(pickedFile);
              selectedImageBytes.add(bytes); // Web-specific storage
              _initializeDrawingsForImage(pickedFile.path);
              successfullyAdded++;
            } else {
              duplicatesSkipped++;
            }
          } catch (e) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Error with "${pickedFile.name}": ${e}')),
            );
          }
        }),
      );

      // Single UI update for performance
      setState(() {
        if (successfullyAdded > 0) {
          selectedIndex = selectedImages.length - 1;
          _clearCurrentDrawing();
        }
      });

      // User feedback
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Added $successfullyAdded image(s). ${duplicatesSkipped > 0 ? "$duplicatesSkipped duplicate(s) skipped." : ""}',
          ),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to select images: ${e}')));
    }
  }

  void goNext() {
    if (selectedImages.isEmpty) return;
    setState(() {
      selectedIndex = (selectedIndex + 1) % selectedImages.length;
      _initializeDrawingsForImage(selectedImages[selectedIndex].path);
      _clearCurrentDrawing();
    });
  }

  void goPrevious() {
    if (selectedImages.isEmpty) return;
    setState(() {
      selectedIndex =
          (selectedIndex - 1 + selectedImages.length) % selectedImages.length;
      _initializeDrawingsForImage(selectedImages[selectedIndex].path);
      _clearCurrentDrawing();
    });
  }

  void _initializeDrawingsForImage(String path) {
    _imageDrawings[path] = _imageDrawings[path] ?? [];
  }

  void _clearCurrentDrawing() {
    _startPoint = null;
    _endPoint = null;
    _labelText = null;
    _isDrawing = false;
    _isLabeling = false;
  }

  void _saveDrawing() {
    if (_startPoint != null && _endPoint != null) {
      // Save current state before change
      _saveUndoState();

      final newDrawing = Drawing(
        startPoint: _startPoint!,
        endPoint: _endPoint!,
        label: _labelText,
        isLocked: true,
      );
      _currentDrawings.add(newDrawing);
      _clearRedoState();
    }
    _clearCurrentDrawing();
  }

  void _saveUndoState() {
    // Store a copy of the current drawings so that we can revert to it later.
    _undoStack.add(_currentDrawings.map((d) => d.copy()).toList());
  }

  void _clearRedoState() {
    _redoStack.clear();
  }

  void _undo() {
    if (_undoStack.isNotEmpty) {
      // Save the current state into the redo stack
      _redoStack.add(_currentDrawings.map((d) => d.copy()).toList());
      // Restore the last saved state
      final previousState = _undoStack.removeLast();
      _imageDrawings[selectedImages[selectedIndex].path] = previousState;
      setState(() {});
    }
  }

  void _redo() {
    if (_redoStack.isNotEmpty) {
      // Save current state into the undo stack
      _undoStack.add(_currentDrawings.map((d) => d.copy()).toList());
      // Restore the next state from the redo stack
      final nextState = _redoStack.removeLast();
      _imageDrawings[selectedImages[selectedIndex].path] = nextState;
      setState(() {});
    }
  }

  void _clearAll() {
    setState(() {
      _saveUndoState(); // Save state before clearing everything
      _imageDrawings[selectedImages[selectedIndex].path] = [];
      _clearRedoState();
      _clearCurrentDrawing();
    });
  }

  void _copyFromImage(int fromIndex) {
    final fromPath = selectedImages[fromIndex].path;
    final drawingsToCopy =
        _imageDrawings[fromPath]?.map((d) => d.copy()).toList() ?? [];
    setState(() {
      _imageDrawings[selectedImages[selectedIndex].path] = drawingsToCopy;
      _redoStack.clear();
    });
  }

  bool _isPointNearLine(Offset p, Offset a, Offset b, double tolerance) {
    final ap = p - a;
    final ab = b - a;
    final abSquared = ab.dx * ab.dx + ab.dy * ab.dy;

    double t = abSquared == 0 ? 0 : (ap.dx * ab.dx + ap.dy * ab.dy) / abSquared;
    t = t.clamp(0.0, 1.0); // Clamp t between 0 and 1

    final closestPoint = Offset(a.dx + ab.dx * t, a.dy + ab.dy * t);
    final distance = (p - closestPoint).distance;

    return distance < tolerance;
  }

  void _showCopyDialog() {
    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            title: Text('Copy labels from...'),
            content: SizedBox(
              width: double.maxFinite,
              height: 200,
              child: ListView.builder(
                itemCount: selectedImages.length,
                itemBuilder: (context, index) {
                  return ListTile(
                    leading:
                        _hasLabels(index)
                            ? Icon(Icons.label, color: Colors.blue)
                            : Icon(Icons.label_off, color: Colors.grey),
                    title: Text('Image ${index + 1}'),
                    onTap: () {
                      Navigator.pop(context);
                      _copyFromImage(index);
                    },
                  );
                },
              ),
            ),
          ),
    );
  }

  void _showContextMenu(
    BuildContext context,
    Offset position,
    Drawing drawing,
  ) async {
    final selected = await showMenu(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx + 1,
        position.dy + 1,
      ),
      items: [
        PopupMenuItem(
          value: 'toggleLock',
          child: Text(drawing.isLocked ? 'Unlock Label' : 'Lock Label'),
        ),
        PopupMenuItem(value: 'delete', child: Text('Delete Label')),
      ],
    );
    if (selected == 'delete') {
      setState(() {
        _saveUndoState(); // Save state before deleting
        _currentDrawings.remove(drawing);
        _clearRedoState();
      });
    } else if (selected == 'toggleLock') {
      setState(() => drawing.isLocked = !drawing.isLocked);
    }
  }

  bool _hasLabels(int index) {
    final path = selectedImages[index].path;
    return _imageDrawings[path]?.isNotEmpty ?? false;
  }

  // bool _isPointNear(Offset point, Offset linePoint, double threshold) {
  //   return (point - linePoint).distance < threshold;
  // }

  // Future<void> _saveImageWithLabels() async {
  //   if (selectedImages.isEmpty) return;

  //   try {
  //     // Show saving indicator
  //     ScaffoldMessenger.of(context).showSnackBar(
  //       SnackBar(
  //         content: Row(
  //           children: [
  //             CircularProgressIndicator(),
  //             SizedBox(width: 20),
  //             Text("Preparing image for download..."),
  //           ],
  //         ),
  //       ),
  //     );

  //     // Get the image bytes
  //     Uint8List imageBytes;
  //     if (kIsWeb) {
  //       imageBytes = selectedImageBytes[selectedIndex];
  //     } else {
  //       imageBytes =
  //           await File(selectedImages[selectedIndex].path).readAsBytes();
  //     }

  //     // Create a canvas to composite the image and drawings
  //     final recorder = ui.PictureRecorder();
  //     final canvas = Canvas(recorder);
  //     final paint = Paint();

  //     // Decode the original image
  //     final codec = await ui.instantiateImageCodec(imageBytes);
  //     final frame = await codec.getNextFrame();
  //     final image = frame.image;

  //     // Calculate aspect ratios
  //     final imageRatio = image.width / image.height;
  //     final targetWidth = image.width.toDouble();
  //     final targetHeight = image.height.toDouble();

  //     // Fill background with black
  //     canvas.drawRect(
  //       Rect.fromLTWH(0, 0, targetWidth, targetHeight),
  //       Paint()..color = Colors.black,
  //     );

  //     // Calculate centered position for the image
  //     final imageWidth = targetWidth;
  //     final imageHeight = targetHeight;
  //     final offsetX = 0.0;
  //     final offsetY = 0.0;

  //     // Draw the image centered on black background
  //     canvas.drawImageRect(
  //       image,
  //       Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
  //       Rect.fromLTWH(offsetX, offsetY, imageWidth, imageHeight),
  //       paint,
  //     );

  //     // Draw all the labels
  //     for (final drawing in _currentDrawings) {
  //       // Scale the drawing points from screen coordinates to image coordinates
  //       final screenSize = MediaQuery.of(context).size;
  //       final scaleX = imageWidth / screenSize.width;
  //       final scaleY = imageHeight / screenSize.height;

  //       final startX = drawing.startPoint.dx * scaleX;
  //       final startY = drawing.startPoint.dy * scaleY;
  //       final endX = drawing.endPoint.dx * scaleX;
  //       final endY = drawing.endPoint.dy * scaleY;

  //       final scaledStart = Offset(startX, startY);
  //       final scaledEnd = Offset(endX, endY);

  //       // Draw the line
  //       final linePaint =
  //           Paint()
  //             ..color = const Color.fromARGB(255, 166, 190, 210)
  //             ..strokeWidth = 2 * (scaleX + scaleY) / 2; // Scale line width

  //       // Calculate the distance between start and end points
  //       final totalLength = (scaledEnd - scaledStart).distance;
  //       final direction = (scaledEnd - scaledStart) / totalLength;
  //       final newEnd = scaledStart + direction * (totalLength * 0.97);

  //       // Draw the first part of the line
  //       canvas.drawLine(scaledStart, newEnd, linePaint);

  //       // Draw the horizontal line
  //       final horizontalDirection = scaledEnd.dx >= scaledStart.dx ? 1.0 : -1.0;
  //       final horizontalEnd = Offset(
  //         newEnd.dx + (totalLength * 0.03 * horizontalDirection),
  //         newEnd.dy,
  //       );
  //       canvas.drawLine(newEnd, horizontalEnd, linePaint);

  //       // Draw the label text
  //       // Draw the label text
  //       if (drawing.label != null && drawing.label!.isNotEmpty) {
  //         final textPainter = TextPainter(
  //           text: TextSpan(
  //             text: drawing.label,
  //             style: TextStyle(
  //               color: Colors.white,
  //               fontSize: 14 * (scaleX + scaleY) / 2, // Scale font size
  //               backgroundColor: Colors.black.withOpacity(0.5),
  //             ),
  //             // Removed textDirection from here
  //           ),
  //           textDirection:
  //               TextDirection.ltr, // Moved textDirection to TextPainter
  //         );
  //         textPainter.layout();

  //         final textOffset =
  //             horizontalDirection == 1.0
  //                 ? horizontalEnd + Offset(10 * scaleX, -textPainter.height / 2)
  //                 : horizontalEnd +
  //                     Offset(
  //                       -10 * scaleX - textPainter.width,
  //                       -textPainter.height / 2,
  //                     );

  //         textPainter.paint(canvas, textOffset);
  //       }
  //     }

  //     // Convert the canvas to an image
  //     final picture = recorder.endRecording();
  //     final img = await picture.toImage(image.width, image.height);
  //     final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
  //     final pngBytes = byteData!.buffer.asUint8List();

  //     // Trigger download
  //     final blob = html.Blob([pngBytes], 'image/png');
  //     final url = html.Url.createObjectUrlFromBlob(blob);
  //     final anchor =
  //         html.AnchorElement(href: url)
  //           ..setAttribute('download', 'labeled_image_${selectedIndex + 1}.png')
  //           ..click();
  //     html.Url.revokeObjectUrl(url);

  //     ScaffoldMessenger.of(context).hideCurrentSnackBar();
  //     ScaffoldMessenger.of(
  //       context,
  //     ).showSnackBar(SnackBar(content: Text('Image saved successfully!')));
  //   } catch (e) {
  //     ScaffoldMessenger.of(context).hideCurrentSnackBar();
  //     ScaffoldMessenger.of(
  //       context,
  //     ).showSnackBar(SnackBar(content: Text('Failed to save image: $e')));
  //   }
  // }

  @override
  void dispose() {
    focusNode.dispose();
    _labelController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: RawKeyboardListener(
        focusNode: focusNode,
        autofocus: true,
        onKey: (RawKeyEvent event) {
          if (event is RawKeyDownEvent) {
            if (event.logicalKey == LogicalKeyboardKey.arrowRight)
              goNext();
            else if (event.logicalKey == LogicalKeyboardKey.arrowLeft)
              goPrevious();
            else if (event.logicalKey == LogicalKeyboardKey.escape) {
              _clearCurrentDrawing();
              setState(() {});
            }
          }
        },
        child: GestureDetector(
          onTapUp: (details) {
            final RenderBox box = context.findRenderObject() as RenderBox;
            final localOffset = box.globalToLocal(details.globalPosition);

            for (final drawing in _currentDrawings.reversed) {
              if (_isPointNearLine(
                localOffset,
                drawing.startPoint,
                drawing.endPoint,
                15,
              )) {
                _showContextMenu(context, details.globalPosition, drawing);
                return;
              }
            }
          },

          onPanStart: (details) {
            final RenderBox box = context.findRenderObject() as RenderBox;
            final localOffset = box.globalToLocal(details.globalPosition);

            for (final drawing in _currentDrawings.reversed) {
              if (!drawing.isLocked) {
                // 👇 NEW: Allow dragging the whole line
                if (_isPointNearLine(
                  localOffset,
                  drawing.startPoint,
                  drawing.endPoint,
                  15,
                )) {
                  _draggingLabel = drawing;
                  _dragOffset = localOffset;
                  return;
                }
              }
            }

            if (localOffset.dy < MediaQuery.of(context).size.height - 100) {
              _startPoint = localOffset;
              _isDrawing = true;
            }
          },

          onPanUpdate: (details) {
            if (_draggingLabel != null && _dragOffset != null) {
              setState(() {
                final delta = details.localPosition - _dragOffset!;
                _draggingLabel!.startPoint += delta;
                _draggingLabel!.endPoint += delta;
                _dragOffset = details.localPosition;
              });
            } else if (_isDrawing) {
              final RenderBox box = context.findRenderObject() as RenderBox;
              _endPoint = box.globalToLocal(details.globalPosition);
              setState(() {});
            }
          },

          onPanEnd: (details) {
            _draggingLabel = null;
            _dragOffset = null;
            if (_isDrawing && _startPoint != null && _endPoint != null) {
              _isLabeling = true;
              _labelText = null;
              _labelController.clear();
              showDialog(
                context: context,
                builder:
                    (context) => AlertDialog(
                      title: Text('Add Label'),
                      content: TextField(
                        controller: _labelController,
                        autofocus: true,
                        decoration: InputDecoration(
                          hintText: 'Enter label text',
                        ),
                        onSubmitted: (text) {
                          setState(() {
                            _labelText = text;
                            _isLabeling = false;
                            _saveDrawing();
                          });
                          Navigator.pop(context);
                        },
                      ),
                      actions: [
                        TextButton(
                          child: Text('Cancel'),
                          onPressed: () {
                            setState(() {
                              _isLabeling = false;
                              _clearCurrentDrawing();
                            });
                            Navigator.pop(context);
                          },
                        ),
                        TextButton(
                          child: Text('OK'),
                          onPressed: () {
                            setState(() {
                              _labelText = _labelController.text;
                              _isLabeling = false;
                              _saveDrawing();
                            });
                            Navigator.pop(context);
                          },
                        ),
                      ],
                    ),
              );
            }
            _isDrawing = false;
          },
          child: Stack(
            children: [
              Column(
                children: [
                  Expanded(
                    child: Stack(
                      children: [
                        Center(
                          child: AnimatedSwitcher(
                            duration: Duration(milliseconds: 500),
                            child:
                                selectedImages.isEmpty
                                    ? Text(
                                      'No image selected',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 18,
                                      ),
                                    )
                                    : kIsWeb
                                    ? (selectedImageBytes.length > selectedIndex
                                        ? Image.memory(
                                          selectedImageBytes[selectedIndex],
                                          key: ValueKey<String>(
                                            selectedImages[selectedIndex].path,
                                          ),
                                          fit: BoxFit.contain,
                                        )
                                        : Center(
                                          child: CircularProgressIndicator(),
                                        ))
                                    : Image.file(
                                      File(selectedImages[selectedIndex].path),
                                      key: ValueKey<String>(
                                        selectedImages[selectedIndex].path,
                                      ),
                                      fit: BoxFit.contain,
                                    ),
                          ),
                        ),
                        for (var drawing in _currentDrawings)
                          CustomPaint(
                            painter: LinePainter(
                              start: drawing.startPoint,
                              end: drawing.endPoint,
                              label: drawing.label,
                            ),
                          ),
                        if (_startPoint != null && _endPoint != null)
                          CustomPaint(
                            painter: LinePainter(
                              start: _startPoint!,
                              end: _endPoint!,
                              label: _labelText,
                              isTemporary: true,
                            ),
                          ),
                      ],
                    ),
                  ),
                  SizedBox(
                    height: 100,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: selectedImages.length,
                      itemBuilder: (context, index) {
                        return GestureDetector(
                          onTap: () {
                            setState(() {
                              selectedIndex = index;
                              _initializeDrawingsForImage(
                                selectedImages[selectedIndex].path,
                              );
                              _clearCurrentDrawing();
                            });
                          },
                          child: Container(
                            margin: EdgeInsets.symmetric(horizontal: 8),
                            padding: EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              border: Border.all(
                                color:
                                    selectedIndex == index
                                        ? Colors.white
                                        : Colors.grey,
                                width: 2,
                              ),
                            ),
                            child: Stack(
                              children: [
                                kIsWeb
                                    ? Image.memory(
                                      selectedImageBytes[index],
                                      width: 80,
                                      height: 80,
                                      fit: BoxFit.cover,
                                    )
                                    : Image.file(
                                      File(selectedImages[index].path),
                                      width: 80,
                                      height: 80,
                                      fit: BoxFit.cover,
                                    ),
                                Positioned(
                                  top: 2,
                                  left: 2,
                                  child: Container(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: 4,
                                      vertical: 2,
                                    ),
                                    color: Colors.black54,
                                    child: Text(
                                      '${index + 1}',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
              Positioned(
                left: 16,
                top: MediaQuery.of(context).size.height / 2 - 28,
                child: IconButton(
                  icon: Icon(
                    Icons.arrow_back_ios_new,
                    color: Colors.white,
                    size: 32,
                  ),
                  onPressed: goPrevious,
                ),
              ),
              Positioned(
                right: 16,
                top: MediaQuery.of(context).size.height / 2 - 28,
                child: IconButton(
                  icon: Icon(
                    Icons.arrow_forward_ios,
                    color: Colors.white,
                    size: 32,
                  ),
                  onPressed: goNext,
                ),
              ),
              Positioned(
                top: 16,
                right: 16,
                child: Row(
                  children: [
                    IconButton(
                      icon: Icon(Icons.image, color: Colors.white, size: 28),
                      onPressed: _pickImage,
                      tooltip: 'Pick Image',
                    ),
                    IconButton(
                      icon: Icon(Icons.undo, color: Colors.white, size: 28),
                      onPressed: _undo,
                      tooltip: 'Undo',
                    ),
                    IconButton(
                      icon: Icon(Icons.redo, color: Colors.white, size: 28),
                      onPressed: _redo,
                      tooltip: 'Redo',
                    ),
                    IconButton(
                      icon: Icon(Icons.clear, color: Colors.white, size: 28),
                      onPressed: _clearAll,
                      tooltip: 'Clear All',
                    ),
                    IconButton(
                      icon: Icon(Icons.copy, color: Colors.white, size: 28),
                      onPressed: _showCopyDialog,
                      tooltip: 'Copy from image...',
                    ),
                    // IconButton(
                    //   icon: Icon(Icons.save, color: Colors.white, size: 28),
                    //   onPressed: null,
                    //   tooltip: 'Save Image',
                    // ),
                  ],
                ),
              ),
              Positioned(
                bottom: 120,
                left: 0,
                right: 0,
                child: Center(
                  child: Text(
                    'Drag on image to draw a label line. Tap line to lock/unlock/delete.',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.7),
                      fontSize: 16,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class Drawing {
  Offset startPoint;
  Offset endPoint;
  final String? label;
  bool isLocked;

  Drawing({
    required this.startPoint,
    required this.endPoint,
    this.label,
    this.isLocked = false,
  });

  Drawing copy() => Drawing(
    startPoint: startPoint,
    endPoint: endPoint,
    label: label,
    isLocked: isLocked,
  );
}

class LinePainter extends CustomPainter {
  final Offset start;
  final Offset end;
  final String? label;
  final bool isTemporary;

  LinePainter({
    required this.start,
    required this.end,
    this.label,
    this.isTemporary = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint =
        Paint()
          ..color =
              isTemporary
                  ? const Color.fromARGB(255, 166, 190, 210)
                  : const Color.fromARGB(255, 166, 190, 210)
          ..strokeWidth = 2;

    // Calculate the distance between start and end points
    final totalLength = (end - start).distance;

    // Calculate the 97% point (the first part of the line)
    final direction =
        (end - start) / totalLength; // unit vector from start to end
    final newEnd = start + direction * (totalLength * 0.97);

    // Draw the first part of the line (80% of the distance)
    canvas.drawLine(start, newEnd, paint);

    // Determine the horizontal direction based on the line's direction
    final horizontalDirection = end.dx >= start.dx ? 1.0 : -1.0;

    // Draw the horizontal line (20% of the distance)
    final horizontalEnd = Offset(
      newEnd.dx + (totalLength * 0.03 * horizontalDirection),
      newEnd.dy,
    );
    canvas.drawLine(newEnd, horizontalEnd, paint);

    // Draw the label next to the endpoint, ensuring it's placed after the end point
    if (label != null && label!.isNotEmpty) {
      final textPainter = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: Colors.white,
            fontSize: 14,
            backgroundColor: Colors.black.withOpacity(0.5),
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();

      // Determine where to place the text based on the direction of the line
      final offset =
          horizontalDirection == 1.0
              ? horizontalEnd +
                  Offset(10, -textPainter.height / 2) // Right side
              : horizontalEnd +
                  Offset(
                    -10 - textPainter.width,
                    -textPainter.height / 2,
                  ); // Left side

      // Draw the label text at the computed offset
      textPainter.paint(canvas, offset);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
