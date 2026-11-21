/// Provider templates that pre-fill hosting targets and suggest deploy methods (spec F3).
class HostingTemplate {
  const HostingTemplate({
    required this.id,
    required this.label,
    this.consoleUrl = '',
    this.deployMethods = const [],
    this.hint = '',
  });
  final String id;
  final String label;
  final String consoleUrl;
  final List<String> deployMethods;
  final String hint;
}

const List<HostingTemplate> hostingTemplates = [
  HostingTemplate(
    id: 'digitalocean',
    label: 'DigitalOcean',
    consoleUrl: 'https://cloud.digitalocean.com',
    deployMethods: [
      'SSH / manual',
      'GitHub Actions',
      'Docker',
      'App Platform (git push)',
      'doctl',
    ],
    hint: 'Droplet, App Platform or managed database. Record the project and region.',
  ),
  HostingTemplate(
    id: 'superhosting',
    label: 'Superhosting',
    // Control panel URL is account specific; left blank for the user to fill in.
    deployMethods: [
      'FTP / SFTP',
      'SSH / manual',
      'Control panel (git)',
      'GitHub Actions',
    ],
    hint: 'Shared hosting. Fill in your control panel URL and how you deploy.',
  ),
  HostingTemplate(
    id: 'aws',
    label: 'AWS',
    consoleUrl: 'https://console.aws.amazon.com',
    deployMethods: ['GitHub Actions', 'SSH / manual', 'Docker'],
  ),
  HostingTemplate(
    id: 'azure',
    label: 'Azure',
    consoleUrl: 'https://portal.azure.com',
    deployMethods: ['GitHub Actions', 'Docker'],
  ),
  HostingTemplate(
    id: 'vercel',
    label: 'Vercel',
    consoleUrl: 'https://vercel.com/dashboard',
    deployMethods: ['git push'],
  ),
  HostingTemplate(
    id: 'vps',
    label: 'Other VPS / server',
    deployMethods: ['SSH / manual', 'Docker', 'GitHub Actions'],
  ),
  HostingTemplate(id: 'other', label: 'Other', deployMethods: []),
];

HostingTemplate templateFor(String provider) => hostingTemplates.firstWhere(
  (t) => t.id == provider,
  orElse: () => hostingTemplates.last,
);

/// Deploy methods offered for any environment, merged with the hosting template's suggestions.
const List<String> baseDeployMethods = [
  'git push',
  'GitHub Actions',
  'Docker',
  'SSH / manual',
  'FTP / SFTP',
  'Control panel (git)',
  'Other',
];

const List<String> environmentNameSuggestions = [
  'production',
  'staging',
  'development',
  'test',
];
