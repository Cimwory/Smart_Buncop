class AdminAccount {
  final String name;
  final String email;
  final bool active;

  const AdminAccount({
    required this.name,
    required this.email,
    required this.active,
  });

  AdminAccount copyWith({
    String? name,
    String? email,
    bool? active,
  }) {
    return AdminAccount(
      name: name ?? this.name,
      email: email ?? this.email,
      active: active ?? this.active,
    );
  }
}

class UserAccount {
  final String name;
  final String email;
  final bool active;

  const UserAccount({
    required this.name,
    required this.email,
    required this.active,
  });

  UserAccount copyWith({
    String? name,
    String? email,
    bool? active,
  }) {
    return UserAccount(
      name: name ?? this.name,
      email: email ?? this.email,
      active: active ?? this.active,
    );
  }
}

class ActivityLogEntry {
  final String time;
  final String actor;
  final String action;
  final String status;

  const ActivityLogEntry({
    required this.time,
    required this.actor,
    required this.action,
    required this.status,
  });
}
