var root = args.Length > 0 ? args[0] : Directory.GetCurrentDirectory();
return await Rift.Conformance.Runner.RunAsync(root);
