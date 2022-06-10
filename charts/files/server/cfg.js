// environment specific data
window.concord = {
    documentationSite: 'https://concord.walmartlabs.com',
    topBar: {
        systemLinks: [
            {
                text: 'GitHub',
                url: 'https://github.com/walmartlabs/concord',
                icon: 'github'
            }
        ]
    }

    {{- if .Values.oidc.enabled }}
    ,loginUrl: '/api/service/oidc/auth'
    ,logoutUrl: '/api/service/oidc/logout'
    {{- end}}
};
