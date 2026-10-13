import 'package:vrx_kit/vrx_kit.dart';

enum ManageAction { init, factsChanged, failed }

class ManageView {
  const ManageView({required this.serving, required this.addresses, this.error});

  /// null until the first reading.
  final bool? serving;

  /// Where a browser finds the page: the name first, then each address.
  final List<String> addresses;
  final String? error;
}

/// The model: serving or not (vrx-manage.service), the device's name and
/// addresses, the last refusal.
class ManageModel extends StoreModel<bool, ManageAction, ManageView> {
  bool? serving;
  String hostname = '';
  List<String> ips = const [];
  String? error;

  @override
  bool get initial => false;

  @override
  ManageAction get bootAction => ManageAction.init;

  @override
  ManageView reduce(bool state, ManageAction action) {
    if (action == ManageAction.factsChanged) error = null;
    return ManageView(
      serving: serving,
      addresses: [
        if (hostname.isNotEmpty) 'http://$hostname.local',
        for (final ip in ips)
          if (ip.isNotEmpty) 'http://$ip',
      ],
      error: error,
    );
  }

  @override
  bool get snapshot => serving ?? false;
}
