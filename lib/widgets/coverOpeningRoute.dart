import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:jellybook/widgets/jellybookImageCache.dart';
import 'package:jellybook/widgets/roundedImageWithShadow.dart';

/// Animates a tapped cover into the center of the destination screen.
/// [pageReady] is optional: readers can keep the cover onscreen until the
/// first page is decoded. The route owns and disposes the notifier.
class CoverOpeningRoute<T> extends PageRouteBuilder<T> {
  CoverOpeningRoute({
    required WidgetBuilder builder,
    required Rect sourceRect,
    required String coverPath,
    ValueNotifier<bool>? pageReady,
    // Set by the reader before popping: page index zero needs no cover fade.
    ValueNotifier<bool>? skipReturnFade,
  }) : pageReady = pageReady,
       skipReturnFade = skipReturnFade,
       super(
          transitionDuration: const Duration(milliseconds: 300),
          // For other pages: keep the 200ms fade, then shrink for 300ms.
          // Page zero skips the fade and shrinks for 300ms.
          reverseTransitionDuration: pageReady == null
              ? Duration.zero
              : const Duration(milliseconds: 500),
          // The collection underneath must remain painted during the return
          // animation; otherwise shrinking the reader reveals a black screen.
          opaque: pageReady == null,
          pageBuilder: (context, animation, secondaryAnimation) =>
              builder(context),
          transitionsBuilder: (context, animation, secondaryAnimation, child) =>
              _CoverOpeningTransition(
            animation: animation,
            sourceRect: sourceRect,
            coverPath: coverPath,
            pageReady: pageReady,
            skipReturnFade: skipReturnFade,
            child: child,
          ),
        );

  final ValueNotifier<bool>? pageReady;
  final ValueNotifier<bool>? skipReturnFade;

  @override
  bool didPop(T? result) {
    // Choose the reverse duration at pop time, once the reader has identified
    // its current page. The route's controller is created on push, before
    // skipReturnFade has a meaningful value.
    if (pageReady != null) {
      controller?.reverseDuration = (skipReturnFade?.value ?? false)
          ? const Duration(milliseconds: 300)
          : const Duration(milliseconds: 500);
    }
    return super.didPop(result);
  }

  @override
  void dispose() {
    skipReturnFade?.dispose();
    pageReady?.dispose();
    super.dispose();
  }
}

class _CoverOpeningTransition extends StatelessWidget {
  const _CoverOpeningTransition({
    required this.animation,
    required this.sourceRect,
    required this.coverPath,
    required this.pageReady,
    required this.skipReturnFade,
    required this.child,
  });

  final Animation<double> animation;
  final Rect sourceRect;
  final String coverPath;
  final ValueNotifier<bool>? pageReady;
  final ValueNotifier<bool>? skipReturnFade;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        animation,
        if (pageReady != null) pageReady!,
        if (skipReturnFade != null) skipReturnFade!,
      ]),
      child: child,
      builder: (context, destination) {
        final size = MediaQuery.sizeOf(context);
        // The reader paints full-screen Image.file(..., fit: BoxFit.contain).
        // Animate the cover into that *same* viewport and use BoxFit.contain
        // for its final image, rather than guessing its intrinsic aspect ratio.
        // The grid's 0.64 aspect ratio is a crop, not the page's dimensions.
        final Rect target;
        if (pageReady != null) {
          target = Offset.zero & size;
        } else {
          const coverAspectRatio = 0.64;
          final width = (size.width * 0.78).clamp(1.0, 360.0).toDouble();
          final height = (width / coverAspectRatio)
              .clamp(1.0, size.height * 0.72)
              .toDouble();
          target = Rect.fromCenter(
            center: Offset(size.width / 2, size.height / 2),
            width: height * coverAspectRatio,
            height: height,
          );
        }
        final progress = Curves.easeOutCubic.transform(
          animation.value.clamp(0.0, 1.0).toDouble(),
        );
        // If measuring a source cover fails, animate from the center.
        final begin = sourceRect.isEmpty ? target : sourceRect;
        final rect = Rect.lerp(begin, target, progress)!;
        final arrived = animation.status == AnimationStatus.completed;
        final ready = pageReady?.value ?? true;

        if (pageReady != null &&
            animation.status == AnimationStatus.reverse) {
          // On Back, first replace the current reader page with the cover.
          // Only after that fade completes do we move the cover to its card.
          final elapsed = 1.0 - animation.value.clamp(0.0, 1.0);
          final onCoverPage = skipReturnFade?.value ?? false;
          // On page zero, shrink immediately over 300ms. On other pages,
          // keep the 200ms fade, then shrink over the final 300ms.
          final coverFade = onCoverPage
              ? 1.0
              : Curves.easeOut.transform(
                  (elapsed * 2.5).clamp(0.0, 1.0).toDouble(),
                );
          final shrink = Curves.easeInOutCubic.transform(
            onCoverPage
                ? elapsed.clamp(0.0, 1.0).toDouble()
                : ((elapsed - 0.4) / 0.6)
                    .clamp(0.0, 1.0)
                    .toDouble(),
          );
          final returningRect = Rect.lerp(target, begin, shrink)!;

          // A card's grid thumbnail may be cropped, while the reader cover
          // uses BoxFit.contain. Fade out the moving cover just as it reaches
          // the original card so those differing fits cannot visibly snap.
          final landingFade = 1.0 -
              ((shrink - 0.88) / 0.12).clamp(0.0, 1.0).toDouble();

          return Stack(
            fit: StackFit.expand,
            children: [
              Opacity(opacity: 1.0 - coverFade, child: destination!),
              IgnorePointer(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ColoredBox(
                      color: Colors.black.withOpacity(
                        0.90 * coverFade * (1.0 - shrink),
                      ),
                    ),
                    Positioned.fromRect(
                      rect: returningRect,
                      child: Opacity(
                        opacity: coverFade * landingFade,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(10 * shrink),
                          child: _ReaderOpeningCover(coverPath: coverPath),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        }

        return Stack(
          fit: StackFit.expand,
          children: [
            destination!,
            IgnorePointer(
              child: AnimatedOpacity(
                opacity: arrived && ready ? 0 : 1,
                duration: const Duration(milliseconds: 140),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ColoredBox(color: Colors.black.withOpacity(0.90)),
                    Positioned.fromRect(
                      rect: rect,
                      child: pageReady == null
                          ? RoundedImageWithShadow(
                              imageUrl: coverPath,
                              radius: 10,
                              shadowColor: Colors.transparent,
                            )
                          : ClipRRect(
                              borderRadius:
                                  BorderRadius.circular(10 * (1 - progress)),
                              child: _ReaderOpeningCover(coverPath: coverPath),
                            ),
                    ),
                    if (arrived && !ready)
                      Positioned(
                        bottom: MediaQuery.paddingOf(context).bottom + 24,
                        left: 0,
                        right: 0,
                        child: const Center(
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Display the uncropped cover in exactly the same viewport and fit mode
/// used by the reader. Grid thumbnails are intentionally cropped to 0.64.
class _ReaderOpeningCover extends StatelessWidget {
  const _ReaderOpeningCover({required this.coverPath});

  final String coverPath;

  @override
  Widget build(BuildContext context) {
    if (coverPath.isEmpty || coverPath.toLowerCase() == 'asset') {
      return Image.asset('assets/images/NoCoverArt.png', fit: BoxFit.contain);
    }
    if (coverPath.startsWith('http://') ||
        coverPath.startsWith('https://')) {
      return CachedNetworkImage(
        imageUrl: coverUrl(coverPath),
        cacheManager: JellyBookCacheManager.instance,
        fit: BoxFit.contain,
        fadeInDuration: Duration.zero,
        fadeOutDuration: Duration.zero,
        placeholderFadeInDuration: Duration.zero,
        placeholder: (context, url) => const SizedBox.shrink(),
        errorWidget: (context, url, error) =>
            Image.asset('assets/images/NoCoverArt.png', fit: BoxFit.contain),
      );
    }
    return Image.file(File(coverPath), fit: BoxFit.contain);
  }
}
