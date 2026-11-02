import 'package:get/get.dart';

/// Base GetX controller shared across Desktop presentation views, matching
/// XUNA Mobile's `BaseGetxController` conventions.
abstract class BaseGetxController extends GetxController {
  final isLoading = false.obs;
  final isLoadingOverlay = false.obs;

  void showLoading() => isLoading.value = true;
  void hideLoading() => isLoading.value = false;

  void showLoadingOverlay() => isLoadingOverlay.value = true;
  void hideLoadingOverlay() => isLoadingOverlay.value = false;
}

