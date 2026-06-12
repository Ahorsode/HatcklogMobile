import 'package:flutter/material.dart';

import '../data/management_repository.dart';
import '../data/management_models.dart';
import '../../../core/models/app_user.dart';

class TeamManagementScreen extends StatefulWidget {
  const TeamManagementScreen({
    super.key,
    required this.managementRepository,
    required this.currentOwner,
  });

  final ManagementRepository managementRepository;
  final AppUser currentOwner;

  @override
  State<TeamManagementScreen> createState() => _TeamManagementScreenState();
}

class _TeamManagementScreenState extends State<TeamManagementScreen> {
  late Future<ManagementSnapshot> _snapshotFuture;

  @override
  void initState() {
    super.initState();
    _snapshotFuture = widget.managementRepository.loadSnapshot(
      widget.currentOwner,
    );
  }

  Future<void> _promote(TeamMemberRecord member, UserRole target) async {
    await widget.managementRepository.promoteTeamMember(
      owner: widget.currentOwner,
      member: member,
      targetRole: target,
    );
    setState(() {
      _snapshotFuture = widget.managementRepository.loadSnapshot(
        widget.currentOwner,
      );
    });
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Role updated and sessions invalidated.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Team Management')),
      body: FutureBuilder<ManagementSnapshot>(
        future: _snapshotFuture,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final snapshot = snap.data!;
          return ListView.builder(
            itemCount: snapshot.teamMembers.length,
            itemBuilder: (context, i) {
              final member = snapshot.teamMembers[i];
              return ListTile(
                title: Text(member.name),
                subtitle: Text(member.role.name),
                trailing: DropdownButton<UserRole>(
                  value: member.role,
                  items: UserRole.values
                      .map(
                        (r) => DropdownMenuItem(value: r, child: Text(r.name)),
                      )
                      .toList(),
                  onChanged: (r) async {
                    if (r == null) return;
                    await _promote(member, r);
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}
