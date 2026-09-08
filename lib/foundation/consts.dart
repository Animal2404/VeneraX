/// If window width is less than this value, it is considered as mobile.
const changePoint = 600;

/// If window width is less than this value, it is considered as tablet.
///
/// If it is more than this value, it is considered as desktop.
const changePoint2 = 1300;

/// Default user agent for http requests.
const webUA =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36";

/// Pages for all comics is started from this value.
const firstPage = 1;

/// Chapters for all comics is started from this value.
const firstChapter = 1;

/// GitHub repository this build belongs to. Single edit point for a fork: the
/// update check, the update package download, the changelog fetch, the
/// repository link, and model release downloads all resolve through these.
const kUpdateRepoOwner = 'Kyosee';
const kUpdateRepoName = 'VeneraX';