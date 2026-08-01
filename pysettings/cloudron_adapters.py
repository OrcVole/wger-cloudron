# Package-owned allauth social adapter; see cloudron_settings.py for why it exists.

# Third Party
from allauth.socialaccount.adapter import DefaultSocialAccountAdapter


class CloudronSocialAccountAdapter(DefaultSocialAccountAdapter):
    """Allow account provisioning for identities the Cloudron has already authenticated.

    allauth's default adapter delegates signup-openness to the account adapter, which in
    wger follows the public-registration toggle; arrivals from the platform's own identity
    provider must not be blocked by it.
    """

    def is_open_for_signup(self, request, sociallogin):
        return True
