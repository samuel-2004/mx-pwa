import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../layout/app_scaffold.dart';
import '../orient_ui/empty_state.dart';
import '../widgets/loading_spinner.dart';

class TermsScreen extends StatelessWidget {
  const TermsScreen({super.key});

  Future<String> _loadAndProcessTerms() async {
    // 1. Load both the Markdown file and the JSON file concurrently
    final responses = await Future.wait([
      rootBundle.loadString('assets/terms.md'),
      rootBundle.loadString('assets/terms.json'),
    ]);

    final markdownTemplate = responses[0];
    final jsonString = responses[1];

    // 2. Decode the JSON data into a Map
    final Map<String, dynamic> data = json.decode(jsonString);

    // 3. Replace placeholders in the markdown with JSON values
    String processedMarkdown = markdownTemplate;
    data.forEach((key, value) {
      processedMarkdown = processedMarkdown.replaceAll('{{$key}}', value?.toString() ?? '');
    });

    return processedMarkdown;
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Terms & Conditions / Licence',
      body: FutureBuilder<String>(
        future: _loadAndProcessTerms(),
        builder: (BuildContext context, AsyncSnapshot<String> snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const LoadingSpinner();
          }

          if (snapshot.hasError) {
            return const EmptyState(
              title: 'Unable to load the terms and conditions.',
            );
          }

          return Markdown(
            data: snapshot.data ?? '',
            padding: const EdgeInsets.all(16),
          );
        },
      ),
    );
  }
}