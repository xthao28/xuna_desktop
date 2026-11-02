import 'package:flutter/cupertino.dart';
import 'package:get/get.dart';
import 'package:xuna_desktop/core/presentation/controllers/base_getx_controller.dart';
import 'package:xuna_desktop/shared/themes/app_colors.dart';
import 'package:xuna_desktop/shared/widgets/widget_src.dart';

mixin GetPageMixin<T extends BaseGetxController> on StatelessWidget {
  T get controller;

  bool get isAppWidget => false;

  @override
  Widget build(BuildContext context) {
    return isAppWidget
        ? buildPage(context)
        : Stack(
            children: [
              buildPage(context),
              Obx(() {
                if (controller.isLoadingOverlay.value) {
                  return IgnorePointer(
                    ignoring: true,
                    child: Container(
                      color: AppColors.xunaScrim,
                      child: const Center(
                        child: CupertinoActivityIndicator(
                          color: AppColors.xunaPaper,
                        ),
                      ),
                    ),
                  );
                }
                return UtilWidget.shrink;
              }),
            ],
          );
  }

  Widget buildPage(BuildContext context);

  Widget baseShowLoading(Widget Function() child, {Color? colorIcon}) {
    return Obx(
      () => controller.isLoading.value
          ? Center(child: UtilWidget.buildLoading(colorIcon: colorIcon))
          : child(),
    );
  }
}
