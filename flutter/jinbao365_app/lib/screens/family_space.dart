import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:jinbao_core/jinbao_core.dart';

/// A family service is supplied only after a trusted endpoint and authenticated
/// session are configured. This screen never substitutes local roles or members.
class FamilySpaceScreen extends StatefulWidget {
  final FamilyGatewayClient? client;
  final String deviceID;
  final VoidCallback? onViewTimeline;
  final Future<Uri?> Function(BuildContext context)? scanInvitation;
  final Widget Function(BuildContext context, Uri invitation)? invitationCodeBuilder;
  final ValueChanged<Family>? onOpenRecords;

  const FamilySpaceScreen({
    super.key,
    this.client,
    required this.deviceID,
    this.onViewTimeline,
    this.scanInvitation,
    this.invitationCodeBuilder,
    this.onOpenRecords,
  });

  @override
  State<FamilySpaceScreen> createState() => _FamilySpaceScreenState();
}

class _FamilySpaceScreenState extends State<FamilySpaceScreen> {
  List<Family> _families = const [];
  GatewayFamilySnapshot? _snapshot;
  List<GatewayJoinRequest> _requests = const [];
  GatewayJoinRequest? _application;
  bool _busy = false;
  String? _error;
  int _generation = 0;

  FamilyGatewayClient get _client => widget.client!;
  bool get _admin =>
      _snapshot?.currentMember.status == FamilyMemberStatus.active &&
      _snapshot?.currentMember.role == FamilyRole.admin;

  @override
  void initState() {
    super.initState();
    if (widget.client != null) _refresh();
  }

  @override
  void didUpdateWidget(covariant FamilySpaceScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.client != widget.client) {
      _generation++;
      _busy = false;
      _families = const [];
      _snapshot = null;
      _requests = const [];
      _application = null;
      if (widget.client != null) _refresh();
    }
  }

  Future<void> _perform(Future<void> Function() operation) async {
    if (_busy) return;
    final generation = _generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await operation();
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        // Do not print exception bodies, bearer credentials or invitation URLs.
        _error = '暂时无法完成，请检查网络或重新登录后重试。';
        _requests = const [];
        _snapshot = null;
        _families = const [];
      });
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _refresh() => _perform(() async {
    final client = _client;
    final families = await client.listFamilies();
    if (!mounted || widget.client != client) return;
    final applications = await client.ownRequests();
    if (!mounted || widget.client != client) return;
    final previousID = _snapshot?.family.id;
    final selected = families.where((family) => family.id == previousID);
    final next = selected.isNotEmpty
        ? selected.first
        : (families.isEmpty ? null : families.first);
    final snapshot = next == null ? null : await client.getFamily(next.id);
    final requests = snapshot != null && snapshot.currentMember.role == FamilyRole.admin
        ? await client.pendingRequests(snapshot.family.id)
        : <GatewayJoinRequest>[];
    if (!mounted || widget.client != client) return;
    setState(() {
      _families = families;
      _snapshot = snapshot;
      _requests = requests;
      final pending = applications.where((request) => request.status == FamilyJoinStatus.pending);
      _application = pending.isNotEmpty
          ? pending.first
          : (applications.isEmpty ? null : applications.first);
    });
  });

  Future<void> _selectFamily(Family family) => _perform(() async {
    final client = _client;
    final snapshot = await client.getFamily(family.id);
    final requests = snapshot.currentMember.role == FamilyRole.admin
        ? await client.pendingRequests(family.id)
        : <GatewayJoinRequest>[];
    if (!mounted || widget.client != client) return;
    setState(() {
      _snapshot = snapshot;
      _requests = requests;
    });
  });

  Future<void> _createFamily() async {
    final values = await _profileDialog(context, create: true);
    if (values == null || !mounted) return;
    await _perform(() async {
      final client = _client;
      final snapshot = await client.createFamily(
        name: values.familyName!,
        displayName: values.displayName,
        relationshipLabel: values.relationship,
        deviceID: widget.deviceID,
      );
      if (!mounted || widget.client != client) return;
      setState(() {
        _families = [..._families, snapshot.family];
        _snapshot = snapshot;
        _requests = const [];
      });
    });
  }

  Future<void> _pasteInvitation() async {
    final text = await showDialog<String>(
      context: context,
      builder: (_) => const _InvitationLinkDialog(),
    );
    if (text == null || !mounted) return;
    final uri = Uri.tryParse(text.trim());
    if (uri == null) {
      setState(() => _error = '邀请链接无效，请向家庭管理员重新获取。');
      return;
    }
    await _inspectInvitation(uri);
  }

  Future<void> _scan() async {
    final scan = widget.scanInvitation;
    if (scan == null) return;
    try {
      final uri = await scan(context);
      if (uri != null && mounted) await _inspectInvitation(uri);
    } catch (_) {
      if (mounted) {
        setState(() => _error = '未能读取邀请码，可以改用邀请链接。');
      }
    }
  }

  Future<void> _inspectInvitation(Uri invitation) async {
    final client = _client;
    GatewayJoinPreview? inspected;
    await _perform(() async {
      inspected = await client.inspectInvitation(invitation);
    });
    final preview = inspected;
    if (preview == null || !mounted || widget.client != client) return;
    final profile = await _profileDialog(context, preview: preview);
    if (profile == null || !mounted || widget.client != client) return;
    await _perform(() async {
      final application = await client.exchangeInvitation(
        preview,
        confirmed: true,
        displayName: profile.displayName,
        relationshipLabel: profile.relationship,
        deviceID: widget.deviceID,
      );
      if (!mounted || widget.client != client) return;
      setState(() => _application = application);
    });
  }

  Future<void> _applicationStatus() => _perform(() async {
    final client = _client;
    final request = await client.requestStatus(_application!.id);
    if (!mounted || widget.client != client) return;
    setState(() => _application = request);
    if (request.status == FamilyJoinStatus.approved) {
      final families = await client.listFamilies();
      final snapshot = await client.getFamily(request.familyID);
      if (!mounted || widget.client != client) return;
      setState(() {
        _families = families;
        _snapshot = snapshot;
      });
    }
  });

  Future<void> _issueInvitation() async {
    final snapshot = _snapshot!;
    final role = await showDialog<FamilyRole>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('邀请加入「${snapshot.family.name}」'),
        children: [
          SimpleDialogOption(
            padding: const EdgeInsets.all(20),
            onPressed: () => Navigator.pop(context, FamilyRole.contributor),
            child: const Text('投稿成员：看记录、添加照片、编辑自己的记录'),
          ),
          SimpleDialogOption(
            padding: const EdgeInsets.all(20),
            onPressed: () => Navigator.pop(context, FamilyRole.viewer),
            child: const Text('查看者：只看家庭记录'),
          ),
        ],
      ),
    );
    if (role == null || !mounted) return;
    final client = _client;
    GatewayInvitation? issued;
    await _perform(() async {
      issued = await client.issueInvitation(snapshot.family.id, role);
    });
    final invitation = issued;
    if (invitation == null || !mounted || widget.client != client) return;
    await showDialog<void>(
      context: context,
      builder: (context) => _IssuedInvitationDialog(
        client: client,
        family: snapshot.family,
        invitation: invitation,
        codeBuilder: widget.invitationCodeBuilder,
      ),
    );
  }

  Future<void> _reviewRequest(GatewayJoinRequest request, bool approve) async {
    final accepted = await _confirm(
      title: approve ? '批准加入家庭？' : '拒绝加入申请？',
      detail: '${request.displayName} · ${request.relationshipLabel}\n申请权限：${_roleName(request.requestedRole)}',
      action: approve ? '批准加入' : '拒绝申请',
    );
    if (!accepted || !mounted) return;
    await _perform(() async {
      final client = _client;
      if (approve) {
        await client.approve(request.id);
      } else {
        await client.deny(request.id);
      }
      final snapshot = await client.getFamily(request.familyID);
      final requests = await client.pendingRequests(request.familyID);
      if (!mounted || widget.client != client) return;
      setState(() {
        _snapshot = snapshot;
        _requests = requests;
      });
    });
  }

  Future<void> _revokeMember(GatewayMember member) async {
    final confirmed = await _confirm(
      title: '撤销成员权限？',
      detail: '撤销 ${member.displayName} 的后续家庭访问权限。已下载的照片无法追回；已签发临时凭据可能在有效期内继续可用。不会删除家庭记录。',
      action: '撤销权限',
    );
    if (!confirmed || !mounted) return;
    await _perform(() async {
      final client = _client;
      await client.revokeMember(member.familyID, member.id);
      final snapshot = await client.getFamily(member.familyID);
      if (!mounted || widget.client != client) return;
      setState(() => _snapshot = snapshot);
    });
  }

  Future<bool> _confirm({
    required String title,
    required String detail,
    required String action,
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(detail),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(action)),
          ],
        ),
      ) ??
      false;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('家庭空间'),
      actions: [
        if (widget.client != null)
          IconButton(onPressed: _busy ? null : _refresh, tooltip: '刷新家庭', icon: const Icon(Icons.refresh)),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text('一起收藏生活', style: TextStyle(fontSize: 25, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        const Text('关系称呼用于展示，实际权限由家庭管理员审批。', style: TextStyle(fontSize: 16)),
        if (widget.onViewTimeline != null) ...[
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: widget.onViewTimeline,
            icon: const Icon(Icons.photo_library_outlined),
            label: const Text('查看时光'),
          ),
        ],
        if (widget.client == null) ...[
          const SizedBox(height: 24),
          const Card(child: Padding(
            padding: EdgeInsets.all(20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('家庭授权服务尚未配置', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
              SizedBox(height: 12),
              Text('当前无法扫码加入、发出邀请或管理成员。可以继续在本机记录，已有爸爸、妈妈的记录继续保留。', style: TextStyle(fontSize: 16)),
            ]),
          )),
        ] else ...[
          const SizedBox(height: 16),
          Wrap(spacing: 12, runSpacing: 8, children: [
            FilledButton.icon(onPressed: _busy ? null : _createFamily, icon: const Icon(Icons.add_home_outlined), label: const Text('创建家庭')),
            OutlinedButton.icon(onPressed: _busy ? null : _pasteInvitation, icon: const Icon(Icons.link), label: const Text('使用邀请链接')),
            if (widget.scanInvitation != null)
              OutlinedButton.icon(onPressed: _busy ? null : _scan, icon: const Icon(Icons.qr_code_scanner), label: const Text('扫码加入')),
          ]),
          if (_busy) const Padding(padding: EdgeInsets.symmetric(vertical: 18), child: LinearProgressIndicator()),
          if (_error != null) Padding(padding: const EdgeInsets.symmetric(vertical: 16), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 16))),
          if (_application != null) _applicationCard(),
          if (_families.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text('我的家庭', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
            for (final family in _families)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(family.name, style: const TextStyle(fontSize: 18)),
                subtitle: Text('家庭编号：${family.id}'),
                trailing: _snapshot?.family.id == family.id ? const Icon(Icons.check_circle_outline) : const Icon(Icons.chevron_right),
                onTap: _busy ? null : () => _selectFamily(family),
              ),
          ] else if (!_busy && _error == null)
            const Padding(padding: EdgeInsets.symmetric(vertical: 24), child: Text('还没有加入家庭。创建一个家庭，或向管理员获取邀请。', style: TextStyle(fontSize: 16))),
          if (_snapshot != null) ..._familyDetails(),
        ],
      ],
    ),
  );

  Widget _applicationCard() => Card(child: Padding(
    padding: const EdgeInsets.all(16),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(_joinStatus(_application!.status), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      const Text('提交申请不代表已经取得家庭访问权限。'),
      const SizedBox(height: 8),
      OutlinedButton(onPressed: _busy ? null : _applicationStatus, child: const Text('查看申请状态')),
    ]),
  ));

  List<Widget> _familyDetails() {
    final snapshot = _snapshot!;
    return [
      const Divider(height: 32),
      Text(snapshot.family.name, style: const TextStyle(fontSize: 23, fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      Text('我的权限：${_roleName(snapshot.currentMember.role)}', style: const TextStyle(fontSize: 16)),
      if (widget.onOpenRecords != null) ...[
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _busy ? null : () => widget.onOpenRecords!(snapshot.family),
          icon: const Icon(Icons.photo_library_outlined),
          label: const Text('查看家庭记录'),
        ),
      ],
      if (_admin) ...[
        const SizedBox(height: 12),
        FilledButton.icon(onPressed: _busy ? null : _issueInvitation, icon: const Icon(Icons.person_add_alt), label: const Text('邀请家人')),
      ],
      const SizedBox(height: 20),
      const Text('家庭成员', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
      for (final member in snapshot.members)
        Card(child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${member.displayName} · ${member.relationshipLabel}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w500)),
            const SizedBox(height: 6),
            Text('${_roleName(member.role)} · ${member.status == FamilyMemberStatus.active ? '已加入' : '已撤销'}'),
            const SizedBox(height: 6),
            Text('成员编号：${member.id}', style: Theme.of(context).textTheme.bodySmall),
            Text('已关联 ${member.deviceIDs.length} 台设备', style: Theme.of(context).textTheme.bodySmall),
            if (_admin && member.status == FamilyMemberStatus.active && member.id != snapshot.currentMember.id)
              TextButton(onPressed: _busy ? null : () => _revokeMember(member), child: const Text('撤销成员权限')),
          ]),
        )),
      if (_admin) ...[
        const SizedBox(height: 20),
        const Text('待审批申请', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
        if (_requests.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Text('暂无待审批申请')),
        for (final request in _requests)
          Card(child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${request.displayName} · ${request.relationshipLabel}', style: const TextStyle(fontSize: 18)),
              Text('申请权限：${_roleName(request.requestedRole)}'),
              const SizedBox(height: 12),
              Wrap(spacing: 12, children: [
                FilledButton(onPressed: _busy ? null : () => _reviewRequest(request, true), child: const Text('批准')),
                OutlinedButton(onPressed: _busy ? null : () => _reviewRequest(request, false), child: const Text('拒绝')),
              ]),
            ]),
          )),
      ],
    ];
  }
}

class _IssuedInvitationDialog extends StatefulWidget {
  final FamilyGatewayClient client;
  final Family family;
  final GatewayInvitation invitation;
  final Widget Function(BuildContext context, Uri invitation)? codeBuilder;
  const _IssuedInvitationDialog({required this.client, required this.family, required this.invitation, this.codeBuilder});

  @override
  State<_IssuedInvitationDialog> createState() => _IssuedInvitationDialogState();
}

class _IssuedInvitationDialogState extends State<_IssuedInvitationDialog> {
  bool _revoking = false;
  String? _error;

  Future<void> _revoke() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('撤销此邀请？'),
        content: const Text('此邀请将不能继续使用，相关待审批申请也会取消。已加入的成员不会因此被撤销。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('确认撤销')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _revoking = true);
    try {
      await widget.client.revokeInvitation(widget.family.id, widget.invitation.id);
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) setState(() => _error = '撤销未完成，请检查网络后重试。');
    } finally {
      if (mounted) setState(() => _revoking = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('邀请加入「${widget.family.name}」'),
    content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('申请权限：${_roleName(widget.invitation.requestedRole)}'),
      const SizedBox(height: 8),
      Text('有效至：${_localTime(widget.invitation.expiresAt)}'),
      const SizedBox(height: 8),
      const Text('邀请仅可使用一次；对方确认后仍需管理员审批。请只分享给要加入的家人。'),
      if (widget.codeBuilder != null) ...[
        const SizedBox(height: 16),
        widget.codeBuilder!(context, widget.invitation.url),
      ],
      if (_error != null) Text(_error!),
    ])),
    actions: [
      TextButton(onPressed: _revoking ? null : _revoke, child: const Text('撤销此邀请')),
      OutlinedButton(onPressed: _revoking ? null : () async {
        try {
          await Clipboard.setData(ClipboardData(text: widget.invitation.url.toString()));
          if (context.mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('邀请链接已复制，请仅分享给家人。')));
        } catch (_) {
          if (mounted) setState(() => _error = '未能复制邀请链接，请重试。');
        }
      }, child: const Text('复制邀请链接')),
      FilledButton(onPressed: _revoking ? null : () => Navigator.pop(context), child: const Text('完成')),
    ],
  );
}

class _ProfileValues {
  final String? familyName;
  final String displayName;
  final String relationship;
  const _ProfileValues(this.familyName, this.displayName, this.relationship);
}

Future<_ProfileValues?> _profileDialog(BuildContext context, {bool create = false, GatewayJoinPreview? preview}) =>
    showDialog<_ProfileValues>(context: context, builder: (_) => _ProfileDialog(create: create, preview: preview));

class _ProfileDialog extends StatefulWidget {
  final bool create;
  final GatewayJoinPreview? preview;
  const _ProfileDialog({required this.create, this.preview});

  @override
  State<_ProfileDialog> createState() => _ProfileDialogState();
}

class _ProfileDialogState extends State<_ProfileDialog> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _displayName = TextEditingController();
  final _relationship = TextEditingController();
  String? _validate(String? text) {
    final value = text?.trim() ?? '';
    return value.isEmpty || value.length > 80 || value.runes.any((r) => r < 32 || r == 127)
        ? '请填写 1 至 80 个可见字符'
        : null;
  }

  @override
  void dispose() {
    _name.dispose();
    _displayName.dispose();
    _relationship.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.create ? '创建家庭' : '确认加入家庭'),
    content: SingleChildScrollView(child: Form(key: _form, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (widget.preview case final preview?) ...[
        Text('家庭：${preview.familyName}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Text('申请权限：${_roleName(preview.requestedRole)}'),
        Text('邀请有效至：${_localTime(preview.expiresAt)}'),
        const SizedBox(height: 8),
        const Text('提交后等待管理员审批，审批前不能读取或上传家庭内容。'),
        const SizedBox(height: 16),
      ],
      if (widget.create) TextFormField(controller: _name, decoration: const InputDecoration(labelText: '家庭名称'), validator: _validate, maxLength: 80),
      TextFormField(controller: _displayName, decoration: const InputDecoration(labelText: '我的昵称'), validator: _validate, maxLength: 80),
      TextFormField(controller: _relationship, decoration: const InputDecoration(labelText: '关系称呼', hintText: '例如奶奶、外公或自定义称呼'), validator: _validate, maxLength: 80),
    ]))),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
      FilledButton(onPressed: () {
        if (_form.currentState!.validate()) {
          Navigator.pop(context, _ProfileValues(widget.create ? _name.text.trim() : null, _displayName.text.trim(), _relationship.text.trim()));
        }
      }, child: Text(widget.create ? '创建' : '确认并申请加入')),
    ],
  );
}

class _InvitationLinkDialog extends StatefulWidget {
  const _InvitationLinkDialog();
  @override
  State<_InvitationLinkDialog> createState() => _InvitationLinkDialogState();
}

class _InvitationLinkDialogState extends State<_InvitationLinkDialog> {
  final _link = TextEditingController();
  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('使用邀请链接'),
    content: TextField(controller: _link, autocorrect: false, enableSuggestions: false, decoration: const InputDecoration(labelText: '管理员发来的邀请链接')),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
      FilledButton(onPressed: () => Navigator.pop(context, _link.text), child: const Text('查看邀请')),
    ],
  );
}

String _roleName(FamilyRole role) => switch (role) {
  FamilyRole.admin => '管理员',
  FamilyRole.contributor => '投稿成员',
  FamilyRole.viewer => '查看者',
};

String _joinStatus(FamilyJoinStatus status) => switch (status) {
  FamilyJoinStatus.pending => '等待管理员审批',
  FamilyJoinStatus.approved => '申请已批准',
  FamilyJoinStatus.denied => '申请已拒绝',
  FamilyJoinStatus.revoked => '申请已撤销',
};

String _localTime(DateTime instant) {
  final local = instant.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
}
