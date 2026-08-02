// babel-preset-expo replaces `process.env.EXPO_PUBLIC_*` only where it is
// written out literally. A computed lookup — `process.env[name]` — is left
// alone, and nothing populates process.env in a release bundle, so reading
// these dynamically yields null on a device however the values were supplied.
// Metro's dev server hides this by injecting them at runtime, which is why the
// simulator worked.
//
// Spelling each name out here is what actually gets the values into the build.
// A variable added to .env.local must be added to this map too, or it will
// silently read as unset.
export const inlinedEnv: Record<string, string | undefined> = {
  EXPO_PUBLIC_TOLARIA_DEV_VAULT_URL: process.env.EXPO_PUBLIC_TOLARIA_DEV_VAULT_URL,
  EXPO_PUBLIC_TOLARIA_LAYOUT_PROBE: process.env.EXPO_PUBLIC_TOLARIA_LAYOUT_PROBE,
  EXPO_PUBLIC_TOLARIA_NATIVE_VAULT_ALIAS: process.env.EXPO_PUBLIC_TOLARIA_NATIVE_VAULT_ALIAS,
  EXPO_PUBLIC_TOLARIA_NATIVE_VAULT_LABEL: process.env.EXPO_PUBLIC_TOLARIA_NATIVE_VAULT_LABEL,
  EXPO_PUBLIC_TOLARIA_NATIVE_VAULT_URI: process.env.EXPO_PUBLIC_TOLARIA_NATIVE_VAULT_URI,
  EXPO_PUBLIC_TOLARIA_SCENARIO: process.env.EXPO_PUBLIC_TOLARIA_SCENARIO,
  EXPO_PUBLIC_TOLARIA_TABLET_TRANSITION_PROBE:
    process.env.EXPO_PUBLIC_TOLARIA_TABLET_TRANSITION_PROBE,
  EXPO_PUBLIC_TOLARIA_WORKSPACE_SOURCE: process.env.EXPO_PUBLIC_TOLARIA_WORKSPACE_SOURCE,
}
