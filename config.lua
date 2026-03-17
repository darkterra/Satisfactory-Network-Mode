return {
  master = {
    slavesDir = "slaves",
    githubSubPath = "",
    githubRepo = "darkterra/Satisfactory-Network-Mode",
    githubBranch = "main"
  },
  features = {
    master = true,
    network = true
  },
  network = {
    basePort = 100,
    identity = "Master"
  }
}