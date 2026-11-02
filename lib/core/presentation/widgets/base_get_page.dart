import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:xuna_desktop/core/presentation/controllers/base_getx_controller.dart';
import 'package:xuna_desktop/core/presentation/widgets/get_page_mixin.dart';

/// Base page widget matching `xuna_mobile`'s `BaseGetPage<T>`, supporting either
/// an explicitly passed [injectedController] (for unit/widget tests) or GetX DI lookup.
abstract class BaseGetPage<T extends BaseGetxController> extends StatelessWidget
    with GetPageMixin<T> {
  const BaseGetPage({super.key, this.injectedController});

  final T? injectedController;

  @override
  T get controller => injectedController ?? Get.find<T>();
}

