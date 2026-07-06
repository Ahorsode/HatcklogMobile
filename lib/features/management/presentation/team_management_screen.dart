import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/models/app_user.dart';
import '../../../core/permissions/farm_permissions.dart';
import '../../../core/permissions/navigation_permissions.dart';
import '../../../core/permissions/staff_permission_defaults.dart';
import '../../team/data/team_repository.dart';
import '../data/management_models.dart';

class TeamManagementScreen extends StatefulWidget {
  const TeamManagementScreen({
    super.key,
    required this.teamRepository,
    required this.currentUser,
    required this.permissions,
    required this.isFarmOwner,
  });

  final TeamRepository teamRepository;
  final AppUser currentUser;
  final FarmPermissions permissions;
  final bool isFarmOwner;

  @override
  State<TeamManagementScreen> createState() => _TeamManagementScreenState();
}

class _TeamManagementScreenState extends State<TeamManagementScreen> {
  late Future<TeamSnapshot> _snapshotFuture;
  bool _busy = false;

  static const _assignableRoles = <UserRole>[
    UserRole.worker,
    UserRole.cashier,
    UserRole.manager,
    UserRole.accountant,
    UserRole.financeOfficer,
  ];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    setState(() {
      _snapshotFuture = widget.teamRepository.loadSnapshot(
        currentUser: widget.currentUser,
        permissions: widget.permissions,
        isFarmOwner: widget.isFarmOwner,
      );
    });
  }

  Future<void> _promote(TeamMemberRecord member, UserRole targetRole) async {
    if (_busy || member.role == targetRole) {
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.teamRepository.promoteTeamMember(
        owner: widget.currentUser,
        member: member,
        targetRole: targetRole,
      );
      if (!mounted) {
        return;
      }
      _reload();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Role updated. Active sessions will be refreshed.'),
        ),
      );
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Role update failed: $error')),
      );
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _openPermissions(TeamMemberRecord member) async {
    final existing = await widget.teamRepository.loadMemberPermissions(
      farmId: widget.currentUser.activeFarmId,
      userId: member.userId,
    );
    final defaults = defaultPermissionsForRole(member.role.apiRole);
    var draft = existing ?? defaults;

    if (!mounted) {
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 8,
                bottom: MediaQuery.viewInsetsOf(context).bottom + 24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Access Control — ${member.name}',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  Text(
                    'Role: ${formatRoleLabel(member.role.apiRole)}',
                    style: const TextStyle(color: Colors.black54),
                  ),
                  const SizedBox(height: 12),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final module in teamPermissionModules) ...[
                          SwitchListTile(
                            title: Text('${module.label} — View'),
                            value: draft.toMap()[module.viewKey] ?? false,
                            onChanged: _busy
                                ? null
                                : (value) {
                                    HapticFeedback.selectionClick();
                                    setModalState(() {
                                      draft = setPermission(
                                        draft,
                                        module.viewKey,
                                        value,
                                      );
                                    });
                                  },
                          ),
                          SwitchListTile(
                            title: Text('${module.label} — Edit'),
                            value: draft.toMap()[module.editKey] ?? false,
                            onChanged: _busy
                                ? null
                                : (value) {
                                    HapticFeedback.selectionClick();
                                    setModalState(() {
                                      draft = setPermission(
                                        draft,
                                        module.editKey,
                                        value,
                                      );
                                    });
                                  },
                          ),
                        ],
                      ],
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () {
                            setModalState(() {
                              draft = defaults;
                            });
                          },
                    icon: const Icon(Icons.restore),
                    label: Text(
                      'Reset to ${formatRoleLabel(member.role.apiRole)} defaults',
                    ),
                  ),
                  const SizedBox(height: 8),
                  FilledButton(
                    onPressed: _busy
                        ? null
                        : () async {
                            setState(() => _busy = true);
                            try {
                              await widget.teamRepository.updateMemberPermissions(
                                owner: widget.currentUser,
                                targetUserId: member.userId,
                                permissions: draft,
                              );
                              if (context.mounted) {
                                Navigator.of(context).pop();
                              }
                              _reload();
                            } finally {
                              if (mounted) {
                                setState(() => _busy = false);
                              }
                            }
                          },
                    child: const Text('Save & Apply'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Team Management')),
      body: FutureBuilder<TeamSnapshot>(
        future: _snapshotFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting &&
              !snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final data =
              snapshot.data ??
              TeamSnapshot(
                members: const [],
                currentUserRole: widget.currentUser.role,
                isAbsoluteOwner: widget.isFarmOwner,
                canViewTeam: false,
                canEditTeam: false,
                canInvite: false,
                canManagePermissions: false,
                canChangeRoles: false,
              );

          if (!data.canViewTeam) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'You do not have permission to view team management.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          if (data.members.isEmpty) {
            return const Center(
              child: Text('No team members are cached locally yet.'),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: data.members.length,
            separatorBuilder: (context, index) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final member = data.members[index];
              final isOwnerMember = member.role == UserRole.owner;
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        member.name,
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 16,
                        ),
                      ),
                      if (member.phone.isNotEmpty)
                        Text(
                          member.phone,
                          style: const TextStyle(color: Colors.black54),
                        ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: data.canChangeRoles && !isOwnerMember
                                ? DropdownButtonFormField<UserRole>(
                                    initialValue: _assignableRoles.contains(
                                      member.role,
                                    )
                                        ? member.role
                                        : UserRole.worker,
                                    decoration: const InputDecoration(
                                      labelText: 'Role',
                                      isDense: true,
                                    ),
                                    items: _assignableRoles
                                        .map(
                                          (role) => DropdownMenuItem(
                                            value: role,
                                            child: Text(role.label),
                                          ),
                                        )
                                        .toList(),
                                    onChanged: _busy
                                        ? null
                                        : (role) {
                                            if (role != null) {
                                              _promote(member, role);
                                            }
                                          },
                                  )
                                : Chip(
                                    label: Text(formatRoleLabel(member.role.apiRole)),
                                  ),
                          ),
                          if (data.canManagePermissions && !isOwnerMember) ...[
                            IconButton(
                              tooltip: 'Edit permissions',
                              onPressed: _busy
                                  ? null
                                  : () => _openPermissions(member),
                              icon: const Icon(Icons.admin_panel_settings_outlined),
                            ),
                            IconButton(
                              tooltip: 'Reset to role defaults',
                              onPressed: _busy
                                  ? null
                                  : () async {
                                      setState(() => _busy = true);
                                      try {
                                        await widget.teamRepository
                                            .resetMemberPermissions(
                                          owner: widget.currentUser,
                                          member: member,
                                        );
                                        _reload();
                                      } finally {
                                        if (mounted) {
                                          setState(() => _busy = false);
                                        }
                                      }
                                    },
                              icon: const Icon(Icons.restore),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
