import Foundation

@main
struct CommunityLinkChecks {
    static func main() {
        let token = String(repeating: "a", count: 43)
        let good = ["https://voiid.app/c/voiid_jobs", "https://www.voiid.app:443/c/voiid_feedback?i=\(token)", "https://voiid.app/c/VOIID_UPDATES"]
        let bad = ["http://voiid.app/c/voiid_jobs", "https://voiid.app.evil.test/c/voiid_jobs", "https://evil.test/c/voiid_jobs", "https://u@voiid.app/c/voiid_jobs", "https://voiid.app:444/c/voiid_jobs", "https://voiid.app/c/voiid_jobs#anything", "https://voiid.app/c/../users", "https://voiid.app/c/%2e%2e%2fusers", "https://voiid.app/c/voiid_jobs?i=bad", "https://voiid.app/c/voiid_jobs?i", "https://voiid.app/c/voiid_jobs?i=", "https://voiid.app/c/voiid_jobs?i=\(token)&i=\(token)", "voiid://c/voiid_jobs"]
        for raw in good { precondition(CommunityLink.parse(URL(string: raw)) != nil, "Rejected valid link") }
        for raw in bad { precondition(CommunityLink.parse(URL(string: raw)) == nil, "Accepted invalid link: \(raw)") }
        let roundtrip = CommunityLink.parse(URL(string: CommunityLink.format(handle: "voiid_jobs", inviteToken: token)))
        precondition(roundtrip?.inviteToken == token && roundtrip?.handle == "voiid_jobs")
        print("Community QR parser: \(good.count + bad.count + 1) checks passed")
    }
}
