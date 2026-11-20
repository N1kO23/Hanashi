import 'package:material_ui/material_ui.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import '../media/gif_view.dart';

/// A custom emoji's picture, fitted into a [size] square; nothing until it
/// is here.
class CustomEmojiImage extends StatelessWidget {
  const CustomEmojiImage({super.key, required this.name, required this.picture, required this.size});

  final String name;
  final MediaRef picture;
  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
    label: ':$name:',
    image: true,
    child: SizedBox.square(
      dimension: size,
      child: UploadedImage(media: picture, fit: BoxFit.contain, placeholder: const SizedBox()),
    ),
  );
}
