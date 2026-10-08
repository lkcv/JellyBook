import 'dart:io';

import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:jellybook/widgets/jellybookImageCache.dart';

class RoundedImageWithShadow extends StatefulWidget {
  final String imageUrl;
  final double ratio;
  final double radius;
  final Color shadowColor;
  final Function(Size)? onImageSizeAvailable;
  final String errorWidgetAsset;
  final Size? size;

  const RoundedImageWithShadow({
    super.key,
    required this.imageUrl,
    this.ratio = 0.64,
    this.radius = 10,
    this.shadowColor = Colors.black,
    this.onImageSizeAvailable,
    this.errorWidgetAsset = 'assets/images/NoCoverArt.png',
    this.size,
  });

  @override
  _RoundedImageWithShadowState createState() => _RoundedImageWithShadowState();
}

class _RoundedImageWithShadowState extends State<RoundedImageWithShadow> {
  Size? imageSize;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.onImageSizeAvailable != null && imageSize != null) {
        widget.onImageSizeAvailable!(imageSize!);
      }
    });
  }

  Widget _fallback() => Image.asset(
        widget.errorWidgetAsset,
        fit: BoxFit.cover,
        width: imageSize?.width,
        height: imageSize?.height,
      );

  @override
  Widget build(BuildContext context) {
    final url = widget.imageUrl;
    final isAsset = url == '' || url.toLowerCase() == 'asset';

    return Container(
      width: widget.size?.width,
      height: widget.size?.height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(widget.radius),
        boxShadow: [
          BoxShadow(
            color: widget.shadowColor.withOpacity(0.2),
            spreadRadius: 2,
            blurRadius: 5,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(widget.radius),
        child: AspectRatio(
          aspectRatio: widget.ratio,
          child: LayoutBuilder(
            builder: (context, constraints) {
              imageSize = widget.size ?? constraints.biggest;

              if (isAsset) return _fallback();

              if (url.contains('http')) {
                return CachedNetworkImage(
                  imageUrl: coverUrl(url),
                  cacheManager: JellyBookCacheManager.instance,
                  fit: BoxFit.cover,
                  fadeInDuration: Duration.zero,
                  fadeOutDuration: Duration.zero,
                  placeholderFadeInDuration: Duration.zero,
                  placeholder: (context, _) =>
                      Container(color: Colors.grey[900]),
                  errorWidget: (context, _, __) => _fallback(),
                );
              }

              return Image.file(
                File(url),
                fit: BoxFit.cover,
                width: imageSize?.width,
                height: imageSize?.height,
              );
            },
          ),
        ),
      ),
    );
  }
}
