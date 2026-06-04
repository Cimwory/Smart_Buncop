import 'package:flutter/foundation.dart';

import '../models/access_models.dart';

class SuperAdminController extends ChangeNotifier {
  final List<AdminAccount> _admins = const [
    AdminAccount(name: 'Admin One', email: 'admin1@vitaroot.local', active: true),
    AdminAccount(name: 'Admin Two', email: 'admin2@vitaroot.local', active: false),
  ];

  List<AdminAccount> get admins => List.unmodifiable(_admins);

  void setAdminActive(int index, bool active) {
    _admins[index] = _admins[index].copyWith(active: active);
    notifyListeners();
  }
}

class UserManagementController extends ChangeNotifier {
  final List<UserAccount> _users = const [
    UserAccount(name: 'User A', email: 'usera@vitaroot.local', active: true),
    UserAccount(name: 'User B', email: 'userb@vitaroot.local', active: false),
    UserAccount(name: 'User C', email: 'userc@vitaroot.local', active: true),
  ];

  List<UserAccount> get users => List.unmodifiable(_users);

  void setUserActive(int index, bool active) {
    _users[index] = _users[index].copyWith(active: active);
    notifyListeners();
  }
}

class ActivityLogController {
  const ActivityLogController();

  List<ActivityLogEntry> get logs => const [
        ActivityLogEntry(
          time: '2026-02-21 08:10',
          actor: 'usera@vitaroot.local',
          action: 'Login',
          status: 'Success',
        ),
        ActivityLogEntry(
          time: '2026-02-21 08:16',
          actor: 'userb@vitaroot.local',
          action: 'Open Device',
          status: 'Blocked (inactive)',
        ),
        ActivityLogEntry(
          time: '2026-02-21 08:20',
          actor: 'userc@vitaroot.local',
          action: 'Update Settings',
          status: 'Success',
        ),
      ];
}
