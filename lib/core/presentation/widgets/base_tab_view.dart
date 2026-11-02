import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:xuna_desktop/core/presentation/controllers/base_getx_controller.dart';

/// Base tab view widget for modular tab screens inside a `BaseGetPage`.
abstract class BaseTabView<T extends BaseGetxController>
    extends StatelessWidget {
  const BaseTabView({super.key, required this.controller});

  final T controller;

  @override
  Widget build(BuildContext context) => Obx(() => buildTab(context));

  Widget buildTab(BuildContext context);
}

